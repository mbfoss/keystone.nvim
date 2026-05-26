local M = {}

---@class keystone.queryflags.FlagDef
---@field name   string
---@field type   "boolean"|"value"
---@field multi  boolean?   -- allow multiple occurrences (type=value only)
---@field values string[]?  -- known values offered in completion (type=value only)
---@field desc   string?    -- shown in the completion menu

---@class keystone.queryflags.ParseResult
---@field query       string    -- text before the first --flag token
---@field flags       table     -- {[name] = true | string | string[]}
---@field sep_start_0 integer?  -- 0-indexed byte col of the first '--' token, nil when absent

-- Returns the 1-indexed byte position of the first '--word' token (at line start or after whitespace).
local function find_flag_start(raw)
    local p = 1
    while p <= #raw do
        local i = raw:find("%-%-", p)
        if not i then return nil end
        if i == 1 or raw:sub(i - 1, i - 1):match("%s") then
            return i
        end
        p = i + 1
    end
    return nil
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
    local flag_start = find_flag_start(raw)
    if not flag_start then
        return { query = raw, flags = {}, sep_start_0 = nil }
    end

    local query     = raw:sub(1, flag_start - 1):gsub("%s+$", "")
    local flags_str = raw:sub(flag_start)
    local defs      = build_map(schema)
    local flags     = {}

    local tokens = {}
    for tok in flags_str:gmatch("%S+") do
        table.insert(tokens, tok)
    end

    local i = 1
    while i <= #tokens do
        local tok = tokens[i]
        if tok:sub(1, 2) == "--" then
            local name = tok:sub(3)
            local def  = defs[name]
            if def then
                if def.type == "boolean" then
                    flags[name] = true
                    i = i + 1
                elseif def.type == "value" then
                    local next = tokens[i + 1]
                    if next and next:sub(1, 2) ~= "--" then
                        if def.multi then
                            flags[name] = flags[name] or {}
                            table.insert(flags[name], next)
                        else
                            flags[name] = next
                        end
                        i = i + 2
                    else
                        i = i + 1
                    end
                else
                    i = i + 1
                end
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end

    return { query = query, flags = flags, sep_start_0 = flag_start - 1 }
end

---@param schema keystone.queryflags.FlagDef[]
---@param raw    string
---@return {start:integer, finish:integer, hl:string}[]
function M.highlight(schema, raw)
    local flag_start = find_flag_start(raw)
    if not flag_start then return {} end

    local hls    = {}
    local defs   = build_map(schema)
    local flags_str = raw:sub(flag_start)
    local base_0 = flag_start - 1

    local p = 1
    local pending_value_flag = nil  -- name of last --key flag, expecting a value token next

    while p <= #flags_str do
        local ts, te, tok = flags_str:find("(%S+)", p)
        if not ts then break end

        local tok_s = base_0 + ts - 1
        local tok_e = base_0 + te

        if tok:sub(1, 2) == "--" then
            local name = tok:sub(3)
            local def  = defs[name]
            if def then
                table.insert(hls, { start = tok_s, finish = tok_e, hl = "Keyword" })
                pending_value_flag = def.type == "value" and name or nil
            else
                table.insert(hls, { start = tok_s, finish = tok_e, hl = "Comment" })
                pending_value_flag = nil
            end
        else
            if pending_value_flag then
                table.insert(hls, { start = tok_s, finish = tok_e, hl = "String" })
            end
            pending_value_flag = nil
        end

        p = te + 1
    end

    return hls
end

---@class keystone.queryflags.Completions
---@field startcol integer  -- 1-indexed column for vim.fn.complete()
---@field items    table[]

---@param schema      keystone.queryflags.FlagDef[]
---@param line        string
---@param cursor_byte integer  -- 0-indexed byte offset from nvim_win_get_cursor
---@return keystone.queryflags.Completions?
function M.get_completions(schema, line, cursor_byte)
    local before = line:sub(1, cursor_byte)

    local word_start_1, current_word = before:match(".*%s()(%S*)$")
    if not word_start_1 then
        word_start_1  = 1
        current_word = before
    end

    local defs = build_map(schema)

    -- current word starts with -- → complete flag names
    if current_word:sub(1, 2) == "--" then
        local partial = current_word:sub(3)
        local items   = {}
        for _, def in ipairs(schema) do
            if vim.startswith(def.name, partial) then
                table.insert(items, {
                    word = "--" .. def.name,
                    abbr = "--" .. def.name,
                    menu = def.desc or (def.type == "boolean" and "[flag]" or "[value]"),
                })
            end
        end
        return #items > 0 and { startcol = word_start_1, items = items } or nil
    end

    -- previous word was --key → complete values
    local prev_flag = before:match("%-%-(%S+)%s+%S*$")
    if prev_flag then
        local def = defs[prev_flag]
        if def and def.type == "value" and def.values then
            local items = {}
            for _, v in ipairs(def.values) do
                if vim.startswith(v, current_word) then
                    table.insert(items, { word = v, menu = def.desc or "" })
                end
            end
            return #items > 0 and { startcol = word_start_1, items = items } or nil
        end
    end

    return nil
end

return M
