local M = {}

---@class keystone.queryflags.FlagDef
---@field name   string
---@field type   "boolean"|"value"
---@field multi  boolean?   -- allow multiple occurrences (type=value only)
---@field values string[]?  -- known values offered in completion (type=value only)
---@field desc   string?    -- shown in the completion menu

---@class keystone.queryflags.ParseResult
---@field query       string   -- text before --
---@field flags       table    -- {[name] = true | string | string[]}
---@field sep_start_0 integer? -- 0-indexed byte col of the first '-' of '--', nil when absent

-- Returns sep_start_0 (0-indexed), flags_start_1 (1-indexed start of flag tokens).
-- The '--' must be at position 1 or preceded by whitespace to avoid matching foo--bar.
local function find_sep(raw)
    local p = 1
    while true do
        local i = raw:find("%-%-", p)
        if not i then return nil, nil end
        if i == 1 or raw:sub(i - 1, i - 1):match("%s") then
            local after = i + 2
            local ws    = raw:sub(after):match("^%s+")
            if ws then return i - 1, after + #ws end
        end
        p = i + 1
    end
end

local function build_map(schema)
    local m = {}
    for _, def in ipairs(schema) do m[def.name] = def end
    return m
end

---@param schema keystone.queryflags.FlagDef[]
---@param raw    string
---@return keystone.queryflags.ParseResult
function M.parse(schema, raw)
    local sep_start_0, flags_start_1 = find_sep(raw)
    if not sep_start_0 then
        return { query = raw, flags = {}, sep_start_0 = nil }
    end
    ---@cast sep_start_0  integer
    ---@cast flags_start_1 integer

    local query     = raw:sub(1, sep_start_0):gsub("%s+$", "")
    local flags_str = raw:sub(flags_start_1)
    local defs      = build_map(schema)
    local flags     = {}

    for token in flags_str:gmatch("%S+") do
        local name, value = token:match("^([%w_%-]+):(.*)$")
        if name then
            local def = defs[name]
            if def and def.type == "value" then
                if def.multi then
                    flags[name] = flags[name] or {}
                    table.insert(flags[name], value)
                else
                    flags[name] = value
                end
            end
        else
            local def = defs[token]
            if def and def.type == "boolean" then
                flags[token] = true
            end
        end
    end

    return { query = query, flags = flags, sep_start_0 = sep_start_0 }
end

---@param schema keystone.queryflags.FlagDef[]
---@param raw    string
---@return {start:integer, finish:integer, hl:string}[]
function M.highlight(schema, raw)
    local sep_start_0, flags_start_1 = find_sep(raw)
    if not sep_start_0 then return {} end
    ---@cast sep_start_0  integer
    ---@cast flags_start_1 integer

    local hls  = {}
    local defs = build_map(schema)

    table.insert(hls, { start = sep_start_0, finish = sep_start_0 + 2, hl = "Comment" })

    local flags_str = raw:sub(flags_start_1)
    local base_0    = flags_start_1 - 1  -- convert flags-relative positions to line-absolute 0-indexed

    local p = 1
    while p <= #flags_str do
        local ts, te, token = flags_str:find("(%S+)", p)
        if not ts then break end

        local tok_start = base_0 + ts - 1
        local tok_end   = base_0 + te

        local name, value = token:match("^([%w_%-]+):(.*)$")
        if name and defs[name] and defs[name].type == "value" then
            local name_end = tok_start + #name
            table.insert(hls, { start = tok_start,  finish = name_end,     hl = "Keyword" })
            table.insert(hls, { start = name_end,   finish = name_end + 1, hl = "Comment" })
            if #value > 0 then
                table.insert(hls, { start = name_end + 1, finish = tok_end, hl = "String" })
            end
        elseif not name and defs[token] and defs[token].type == "boolean" then
            table.insert(hls, { start = tok_start, finish = tok_end, hl = "Keyword" })
        end

        p = te + 1
    end

    return hls
end

---@class keystone.queryflags.Completions
---@field startcol integer  -- 1-indexed column for vim.fn.complete()
---@field items    table[]

-- cursor_byte is the 0-indexed byte offset from nvim_win_get_cursor.
-- In insert mode at the end of "abc", cursor_byte == 3, so line:sub(1, cursor_byte) == "abc".
---@param schema      keystone.queryflags.FlagDef[]
---@param line        string
---@param cursor_byte integer
---@return keystone.queryflags.Completions?
function M.get_completions(schema, line, cursor_byte)
    local _, flags_start_1 = find_sep(line)
    if not flags_start_1 then return nil end
    if cursor_byte + 1 < flags_start_1 then return nil end

    -- text from flags zone start up to (not including) the cursor character
    local flags_before = line:sub(flags_start_1, cursor_byte)

    local word_start_rel, current_word = flags_before:match(".*%s()(%S*)$")
    if not word_start_rel then
        word_start_rel, current_word = 1, flags_before
    end

    -- 1-indexed column in the full line where the current word starts
    local word_col_1 = flags_start_1 + word_start_rel - 1

    local name, partial_value = current_word:match("^([%w_%-]+):(.*)$")
    local defs = build_map(schema)

    if name then
        local def = defs[name]
        if not def or def.type ~= "value" or not def.values then return nil end
        local items = {}
        for _, v in ipairs(def.values) do
            if vim.startswith(v, partial_value) then
                table.insert(items, { word = name .. ":" .. v, abbr = v, menu = def.desc or "" })
            end
        end
        return #items > 0 and { startcol = word_col_1, items = items } or nil
    else
        local items = {}
        for _, def in ipairs(schema) do
            if vim.startswith(def.name, current_word) then
                local word = def.type == "boolean" and def.name or (def.name .. ":")
                table.insert(items, {
                    word = word,
                    menu = def.desc or (def.type == "boolean" and "[flag]" or "[value]"),
                })
            end
        end
        return #items > 0 and { startcol = word_col_1, items = items } or nil
    end
end

return M
