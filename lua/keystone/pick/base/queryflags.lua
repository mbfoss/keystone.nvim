local M = {}

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

-- Backslash escape sequences: \\ → \, \  → space, \n \t \r → control chars.
-- Any other \x → x. Tokens split on unescaped whitespace.
-- Unescaped ':' is a flag separator; \: is a literal colon (no flag splitting).
--
-- GitHub-style flags:
--   boolean flag:  "is:flagname"   → flags.flagname = true
--   value flag:    "key:value"     → flags.key = value  (or array if multi)
--   anything else: accumulated into query
--
-- To include a literal colon that looks like a flag: escape it with \:
--   e.g.  is\:regex  →  query term "is:regex"

---@class keystone.queryflags.Token
---@field text          string   -- processed text (escapes resolved)
---@field raw           string   -- verbatim slice of source
---@field start         integer  -- 1-indexed start in source
---@field finish        integer  -- 1-indexed finish in source (inclusive)
---@field colon_pos     integer? -- 1-indexed position of first unescaped ':' in text
---@field colon_raw_pos integer? -- 1-indexed position of first unescaped ':' in raw (for buffer offsets)

local _escape = { n = "\n", t = "\t", r = "\r" }

---@param str string
---@return keystone.queryflags.Token[]
local function _tokenize(str)
    local tokens = {}
    local i      = 1
    local len    = #str

    while i <= len do
        while i <= len and str:sub(i, i):match("%s") do i = i + 1 end
        if i > len then break end

        local tok_start     = i
        local chars         = {}
        local colon_pos     = nil
        local colon_raw_pos = nil

        while i <= len do
            local c = str:sub(i, i)
            if c:match("%s") then break end
            if c == "\\" and i + 1 <= len then
                local nxt = str:sub(i + 1, i + 1)
                table.insert(chars, _escape[nxt] or nxt)
                i = i + 2
            else
                if c == ":" and colon_pos == nil then
                    colon_pos     = #chars + 1
                    colon_raw_pos = i - tok_start + 1
                end
                table.insert(chars, c)
                i = i + 1
            end
        end

        local text = table.concat(chars)
        if text ~= "" then
            tokens[#tokens + 1] = {
                text          = text,
                raw           = str:sub(tok_start, i - 1),
                start         = tok_start,
                finish        = i - 1,
                colon_pos     = colon_pos,
                colon_raw_pos = colon_raw_pos,
            }
        end
    end

    return tokens
end

---@param schema keystone.queryflags.FlagDef[]
---@param raw    string
---@return keystone.queryflags.ParseResult
function M.parse(schema, raw)
    local defs        = build_map(schema)
    local flags       = {}
    local query_parts = {}

    for _, token in ipairs(_tokenize(raw)) do
        local colon = token.colon_pos
        if colon then
            local key = token.text:sub(1, colon - 1)
            local val = token.text:sub(colon + 1)
            if key == "is" then
                local def = defs[val]
                if def and def.type == "boolean" then
                    flags[val] = true
                else
                    table.insert(query_parts, token.text)
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
                    table.insert(query_parts, token.text)
                end
            end
        else
            table.insert(query_parts, token.text)
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

    for _, token in ipairs(_tokenize(raw)) do
        local colon_rpos = token.colon_raw_pos
        if colon_rpos then
            local s0  = token.start - 1
            local e0  = token.finish
            local key = token.text:sub(1, token.colon_pos - 1)
            local val = token.text:sub(token.colon_pos + 1)

            if key == "is" then
                local def = defs[val]
                if def and def.type == "boolean" then
                    table.insert(hls, { start = s0,               finish = s0 + colon_rpos, hl = "Keyword" })
                    if #val > 0 then
                        table.insert(hls, { start = s0 + colon_rpos, finish = e0,               hl = "Special" })
                    end
                end
            else
                local def = defs[key]
                if def and def.type == "value" then
                    table.insert(hls, { start = s0,               finish = s0 + colon_rpos, hl = "Keyword" })
                    if #val > 0 then
                        table.insert(hls, { start = s0 + colon_rpos, finish = e0,               hl = "String"  })
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
    local char_after = line:sub(cursor_byte + 1, cursor_byte + 1)
    if char_after ~= "" and not char_after:match("%s") then return nil end

    local before = line:sub(1, cursor_byte)

    local tokens       = _tokenize(before)
    local last         = tokens[#tokens]
    local word_start_1 = #before + 1
    local current_word = ""
    if last and last.finish == #before then
        word_start_1 = last.start
        current_word = last.text
    end

    local colon = last and last.finish == #before and last.colon_pos
    if colon then
        local prefix  = current_word:sub(1, colon - 1)
        local partial = current_word:sub(colon + 1)
        local defs    = build_map(schema)

        if prefix == "is" then
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
            local def = defs[prefix]
            if def and def.type == "value" and def.values then
                local items = {}
                for _, v in ipairs(def.values) do
                    if vim.startswith(v, partial) then
                        table.insert(items, { word = prefix .. ":" .. v, abbr = v })
                    end
                end
                return #items > 0 and { startcol = word_start_1, items = items } or nil
            end
        end
        return nil
    end

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
