local M       = {}
local strutil = require("keystone.util.strutil")

---@class keystone.queryflags.FlagDef
---@field name   string
---@field type   "boolean"|"value"
---@field multi  boolean?   -- allow multiple occurrences (type=value only)
---@field values string[]?  -- known values offered in completion (type=value only)
---@field desc   string?    -- shown in the completion menu

---@class keystone.queryflags.ParseResult
---@field query       string    -- non-flag tokens joined with spaces
---@field flags       table     -- {[name] = true | string | string[]}
---@field sep_start_0 integer?  -- unused, kept for API compatibility

---@class keystone.queryflags.Completions
---@field startcol integer  -- 1-indexed column for vim.fn.complete()
---@field items    table[]

local function build_map(schema)
    local m = {}
    for _, def in ipairs(schema) do m[def.name] = def end
    return m
end

-- GitHub-style format:
--   boolean flag:  "is:flagname"   → flags.flagname = true
--   value flag:    "key:value"     → flags.key = value  (or array if multi)
--   anything else: accumulated into query

---@param schema keystone.queryflags.FlagDef[]
---@param raw    string
---@return keystone.queryflags.ParseResult
function M.parse(schema, raw)
    local defs        = build_map(schema)
    local flags       = {}
    local query_parts = {}

    for _, token in ipairs(strutil.tokenize_shell_args(raw)) do
        local tok   = token.text
        local colon = tok:find(":", 1, true)
        if colon then
            local key = tok:sub(1, colon - 1)
            local val = tok:sub(colon + 1)
            if key == "is" then
                local def = defs[val]
                if def and def.type == "boolean" then
                    flags[val] = true
                else
                    table.insert(query_parts, tok)
                end
            else
                local def = defs[key]
                if def and def.type == "value" and val ~= "" then
                    if def.multi then
                        flags[key] = flags[key] or {}
                        table.insert(flags[key], val)
                    else
                        flags[key] = val
                    end
                else
                    table.insert(query_parts, tok)
                end
            end
        else
            table.insert(query_parts, tok)
        end
    end

    return { query = table.concat(query_parts, " "), flags = flags, sep_start_0 = nil }
end

---@param schema keystone.queryflags.FlagDef[]
---@param raw    string
---@return {start:integer, finish:integer, hl:string}[]
function M.highlight(schema, raw)
    local defs = build_map(schema)
    local hls  = {}

    for _, token in ipairs(strutil.tokenize_shell_args(raw)) do
        local s0    = token.start - 1
        local e0    = token.finish
        local colon = token.raw:find(":", 1, true)

        if colon then
            local key = token.raw:sub(1, colon - 1)
            local val = token.raw:sub(colon + 1)

            if key == "is" then
                local def = defs[val]
                if def and def.type == "boolean" then
                    table.insert(hls, { start = s0,          finish = s0 + colon, hl = "Keyword" })
                    if #val > 0 then
                        table.insert(hls, { start = s0 + colon, finish = e0,          hl = "Special" })
                    end
                end
            else
                local def = defs[key]
                if def and def.type == "value" then
                    table.insert(hls, { start = s0,          finish = s0 + colon, hl = "Keyword" })
                    if #val > 0 then
                        table.insert(hls, { start = s0 + colon, finish = e0,          hl = "String"  })
                    end
                end
            end
        end
    end

    return hls
end

---@param schema      keystone.queryflags.FlagDef[]
---@param line        string
---@param cursor_byte integer  -- 0-indexed byte offset from nvim_win_get_cursor
---@return keystone.queryflags.Completions?
function M.get_completions(schema, line, cursor_byte)
    local before = line:sub(1, cursor_byte)
    local defs   = build_map(schema)

    local tokens       = strutil.tokenize_shell_args(before)
    local last         = tokens[#tokens]
    local word_start_1 = #before + 1
    local current_word = ""
    if last and last.finish == #before then
        word_start_1 = last.start
        current_word = last.text
    end

    local colon = current_word:find(":", 1, true)
    if colon then
        local prefix  = current_word:sub(1, colon - 1)
        local partial = current_word:sub(colon + 1)

        if prefix == "is" then
            -- complete boolean flag names after "is:"
            local items = {}
            for _, def in ipairs(schema) do
                if def.type == "boolean" and vim.startswith(def.name, partial) then
                    table.insert(items, {
                        word = "is:" .. def.name,
                        abbr = def.name,
                        menu = def.desc or "[flag]",
                    })
                end
            end
            return #items > 0 and { startcol = word_start_1, items = items } or nil
        else
            -- complete values after "key:"
            local def = defs[prefix]
            if def and def.type == "value" and def.values then
                local items = {}
                for _, v in ipairs(def.values) do
                    if vim.startswith(v, partial) then
                        table.insert(items, {
                            word = prefix .. ":" .. v,
                            abbr = v,
                        })
                    end
                end
                return #items > 0 and { startcol = word_start_1, items = items } or nil
            end
        end
        return nil
    end

    -- no colon yet: suggest value flag names and individual "is:flagname" items
    if current_word == "" then return nil end
    local items = {}
    for _, def in ipairs(schema) do
        if def.type == "value" and vim.startswith(def.name, current_word) then
            table.insert(items, {
                word = def.name .. ":",
                abbr = def.name,
                menu = def.desc or "[value]",
            })
        elseif def.type == "boolean" and vim.startswith("is:" .. def.name, current_word) then
            table.insert(items, {
                word = "is:" .. def.name,
                abbr = "is:" .. def.name,
                menu = def.desc or "[flag]",
            })
        end
    end
    return #items > 0 and { startcol = word_start_1, items = items } or nil
end

return M
