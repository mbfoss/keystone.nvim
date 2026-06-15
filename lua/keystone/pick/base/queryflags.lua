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

local function _build_map(schema)
    local m = {}
    for _, def in ipairs(schema) do m[def.name] = def end
    return m
end

-- Tokens split on whitespace.  ':' is a flag separator.
--
-- Schema-driven flags:
--   boolean flag:  "flagname"      → flags.flagname = true  (bare token matching a boolean def)
--   value flag:    "key:value"     → flags.key = value  (or string[] if multi)
--   value flag:    'key:"a b c"'   → flags.key = "a b c"  (quote a value to include spaces;
--                                     ' or " both work, and an unterminated quote runs to EOS)
--   anything else: accumulated into query

---@class keystone.queryflags.Token
---@field text          string   -- verbatim token text
---@field raw           string   -- verbatim slice of source
---@field start         integer  -- 1-indexed start in source
---@field finish        integer  -- 1-indexed finish in source (inclusive)
---@field colon_pos     integer? -- 1-indexed position of first ':' in text
---@field colon_raw_pos integer? -- 1-indexed position of first ':' in raw (for buffer offsets)

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
        local quote         = nil  -- active quote char while inside a quoted span

        while i <= len do
            local c = str:sub(i, i)
            if quote then
                -- inside a quoted value: whitespace is literal, quote chars are
                -- stripped from `text` but remain in `raw`.
                if c == quote then
                    quote = nil
                else
                    table.insert(chars, c)
                end
                i = i + 1
            elseif c:match("%s") then
                break
            elseif (c == '"' or c == "'") and colon_pos ~= nil then
                -- opening quote (only meaningful in a value, i.e. after a ':')
                quote = c
                i = i + 1
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
    local defs        = _build_map(schema)
    local flags       = {}
    local query_parts = {}

    for _, token in ipairs(_tokenize(raw)) do
        local colon = token.colon_pos
        if colon then
            local key = token.text:sub(1, colon - 1)
            local val = token.text:sub(colon + 1)
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
        else
            local def = defs[token.text]
            if def and def.type == "boolean" then
                flags[token.text] = true
            else
                table.insert(query_parts, token.text)
            end
        end
    end

    return { query = table.concat(query_parts, " "), flags = flags, sep_start_0 = nil }
end

---@param schema keystone.queryflags.FlagDef[]
---@param raw    string
---@return {start:integer, finish:integer, hl:string}[]
function M.highlight(schema, raw)
    local defs = _build_map(schema)
    local hls  = {}

    for _, token in ipairs(_tokenize(raw)) do
        if token.colon_raw_pos then
            local s0  = token.start - 1
            local e0  = token.finish
            local key = token.text:sub(1, token.colon_pos - 1)
            local val = token.text:sub(token.colon_pos + 1)
            local def = defs[key]
            if def and def.type == "value" then
                table.insert(hls, { start = s0,                        finish = s0 + token.colon_raw_pos, hl = "Keyword" })
                if #val > 0 then
                    table.insert(hls, { start = s0 + token.colon_raw_pos, finish = e0,                        hl = "String"  })
                end
            end
        else
            local def = defs[token.text]
            if def and def.type == "boolean" then
                table.insert(hls, { start = token.start - 1, finish = token.finish, hl = "Special" })
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
        local defs    = _build_map(schema)
        local def     = defs[prefix]
        if def and def.type == "value" and def.values then
            local items = {}
            for _, v in ipairs(def.values) do
                if vim.startswith(v, partial) then
                    local word = v:find("%s")
                        and (prefix .. ':"' .. v .. '"')
                        or (prefix .. ":" .. v)
                    table.insert(items, { word = word, abbr = v })
                end
            end
            return #items > 0 and { startcol = word_start_1, items = items } or nil
        end
        return nil
    end

    local items = {}
    for _, def in ipairs(schema) do
        if def.type == "value" and vim.startswith(def.name, current_word) then
            table.insert(items, {
                word = def.name .. ":",
                abbr = def.name,
                menu = def.desc or "[filter]",
            })
        elseif def.type == "boolean" and vim.startswith(def.name, current_word) then
            table.insert(items, {
                word = def.name,
                abbr = def.name,
                menu = def.desc or "[flag]",
            })
        end
    end
    return #items > 0 and { startcol = word_start_1, items = items } or nil
end

---@param schema keystone.queryflags.FlagDef[]
---@param raw    string
---@return {[1]:string,[2]:string}[]
function M.flag_chunks(schema, raw)
    local defs   = _build_map(schema)
    local chunks = {}

    for _, token in ipairs(_tokenize(raw)) do
        local token_chunks
        if token.colon_pos then
            local key = token.text:sub(1, token.colon_pos - 1)
            local val = token.text:sub(token.colon_pos + 1)
            local def = defs[key]
            if def and def.type == "value" and val ~= "" then
                token_chunks = { { key .. ":", "Keyword" }, { val, "String" } }
            end
        else
            local def = defs[token.text]
            if def and def.type == "boolean" then
                token_chunks = { { token.text, "Special" } }
            end
        end

        if token_chunks then
            if #chunks > 0 then
                table.insert(chunks, { " ", "Comment" })
            end
            vim.list_extend(chunks, token_chunks)
        end
    end

    return chunks
end

return M
