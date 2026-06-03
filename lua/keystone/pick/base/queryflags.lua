local M       = {}
local strutil = require("keystone.util.strutil")

---@class keystone.queryflags.FlagDef
---@field name   string
---@field type   "boolean"|"value"
---@field multi  boolean?   -- allow multiple occurrences (type=value only)
---@field values string[]?  -- known values offered in completion (type=value only)
---@field desc   string?    -- shown in the completion menu

---@class keystone.queryflags.ParseResult
---@field query       string    -- always "" in opts mode (query lives in query_text)
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

-- Format: space-separated tokens; quoted values may contain spaces
--   boolean flag:  "flagname"              → flags.flagname = true
--   value flag:    "key:value"             → flags.key = value  (or array if multi)
--   quoted value:  'key:"val with spaces"' → flags.key = "val with spaces"

---@param schema keystone.queryflags.FlagDef[]
---@param raw    string
---@return keystone.queryflags.ParseResult
function M.parse(schema, raw)
    local defs  = build_map(schema)
    local flags = {}

    for _, token in ipairs(strutil.tokenize_shell_args(raw)) do
        local tok   = token.text
        local colon = tok:find(":", 1, true)
        if colon then
            local key = tok:sub(1, colon - 1)
            local val = tok:sub(colon + 1)
            local def = defs[key]
            if def and def.type == "value" and val ~= "" then
                if def.multi then
                    flags[key] = flags[key] or {}
                    table.insert(flags[key], val)
                else
                    flags[key] = val
                end
            end
        else
            local def = defs[tok]
            if def and def.type == "boolean" then
                flags[tok] = true
            end
        end
    end

    return { query = "", flags = flags, sep_start_0 = nil }
end

---@param schema keystone.queryflags.FlagDef[]
---@param raw    string
---@return {start:integer, finish:integer, hl:string}[]
function M.highlight(schema, raw)
    local defs = build_map(schema)
    local hls  = {}

    for _, token in ipairs(strutil.tokenize_shell_args(raw)) do
        -- Use raw slice for byte positions; extmarks want 0-indexed start, exclusive end
        local s0    = token.start - 1
        local e0    = token.finish
        local colon = token.raw:find(":", 1, true)

        if colon then
            local key = token.raw:sub(1, colon - 1)
            local def = defs[key]
            if def and def.type == "value" then
                table.insert(hls, { start = s0,          finish = s0 + colon, hl = "Keyword" })
                if #token.raw > colon then
                    table.insert(hls, { start = s0 + colon, finish = e0,          hl = "String"  })
                end
            end
        else
            local def = defs[token.text]
            if def and def.type == "boolean" then
                table.insert(hls, { start = s0, finish = e0, hl = "Keyword" })
            end
        end
    end

    return hls
end

---@param schema      keystone.queryflags.FlagDef[]
---@param raw         string
---@param default_hl  string  -- highlight group for unhighlighted spans
---@return {[1]:string,[2]:string}[]
function M.to_virt_text(schema, raw, default_hl)
    local hls    = M.highlight(schema, raw)
    local chunks = {}
    local pos    = 0
    for _, h in ipairs(hls) do
        if h.start > pos then
            chunks[#chunks + 1] = { raw:sub(pos + 1, h.start), default_hl }
        end
        chunks[#chunks + 1] = { raw:sub(h.start + 1, h.finish), h.hl }
        pos = h.finish
    end
    if pos < #raw then
        chunks[#chunks + 1] = { raw:sub(pos + 1), default_hl }
    end
    return chunks
end

---@param schema      keystone.queryflags.FlagDef[]
---@param line        string
---@param cursor_byte integer  -- 0-indexed byte offset from nvim_win_get_cursor
---@return keystone.queryflags.Completions?
function M.get_completions(schema, line, cursor_byte)
    local before = line:sub(1, cursor_byte)
    local defs   = build_map(schema)

    -- Find the token at the cursor position (quote-aware)
    local tokens       = strutil.tokenize_shell_args(before)
    local last         = tokens[#tokens]
    local word_start_1 = #before + 1
    local current_word = ""
    if last and last.finish == #before then
        word_start_1 = last.start
        current_word = last.text
    end

    -- "key:" or "key:partial" → complete values
    local colon = current_word:find(":", 1, true)
    if colon then
        local key         = current_word:sub(1, colon - 1)
        local partial_val = current_word:sub(colon + 1)
        local def         = defs[key]
        if def and def.type == "value" and def.values then
            local items = {}
            for _, v in ipairs(def.values) do
                if vim.startswith(v, partial_val) then
                    table.insert(items, {
                        word = key .. ":" .. v,
                        abbr = v,
                    })
                end
            end
            return #items > 0 and { startcol = word_start_1, items = items } or nil
        end
        return nil
    end

    -- partial flag/key name → complete all matching flags
    local items = {}
    for _, def in ipairs(schema) do
        if vim.startswith(def.name, current_word) then
            local word = def.type == "boolean" and def.name or (def.name .. ":")
            table.insert(items, {
                word = word,
                abbr = def.name,
                menu = def.desc or (def.type == "boolean" and "[flag]" or "[value]"),
            })
        end
    end
    return #items > 0 and { startcol = word_start_1, items = items } or nil
end

return M
