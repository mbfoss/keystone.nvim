local M = {}

-- Reserved key used to set boolean flags, e.g. `is:regex` → flags.regex = true.
local _IS_PREFIX = "is"

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
--   boolean flag:  "is:flagname"   → flags.flagname = true  (flagname matching a boolean def)
--   value flag:    "key:value"     → flags.key = value  (or string[] if multi)
--   anything else: accumulated into query
--
-- Quoting (' or ") works uniformly anywhere in the raw string to include spaces in a token:
--   'key:"a b c"'   → flags.key = "a b c"
--   '"foo bar" baz' → query = "foo bar baz"
-- An unterminated quote runs to end-of-string.

---@class keystone.queryflags.Token
---@field text          string                           -- verbatim token text
---@field raw           string                           -- verbatim slice of source
---@field start         integer                          -- 1-indexed start in source
---@field finish        integer                          -- 1-indexed finish in source (inclusive)
---@field colon_pos     integer?                         -- 1-indexed position of first ':' in text
---@field colon_raw_pos integer?                         -- 1-indexed position of first ':' in raw (for buffer offsets)
---@field quotes        {open:integer,close:integer?}[]? -- raw-relative 1-indexed positions of each quote char; close=nil when unterminated

---@param str string
---@return keystone.queryflags.Token[]
local function _tokenize(str)
    local tokens = {}
    local i      = 1
    local len    = #str

    while i <= len do
        while i <= len and str:sub(i, i):match("%s") do i = i + 1 end
        if i > len then break end

        local tok_start      = i
        local chars          = {}
        local colon_pos      = nil
        local colon_raw_pos  = nil
        local quote          = nil  -- active quote char while inside a quoted span
        local quote_idx      = nil  -- index in `chars` where the active quote opened
        local _quote_spans   = {}
        local _quote_open_raw = nil  -- raw-relative 1-indexed position of the active opening quote

        while i <= len do
            local c = str:sub(i, i)
            if quote then
                -- inside a quoted span: whitespace is literal, matching quote
                -- chars are stripped from `text` but remain in `raw`.
                if c == quote then
                    table.insert(_quote_spans, { open = _quote_open_raw, close = i - tok_start + 1 })
                    _quote_open_raw = nil
                    quote     = nil
                    quote_idx = nil
                else
                    table.insert(chars, c)
                end
                i = i + 1
            elseif c:match("%s") then
                break
            elseif c == '"' or c == "'" then
                -- opening quote: allows whitespace within the token
                _quote_open_raw = i - tok_start + 1
                quote     = c
                quote_idx = #chars + 1
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

        -- An unterminated quote is not a real delimiter: keep it as a literal
        -- char instead of silently swallowing it.
        if quote and quote_idx then
            table.insert(chars, quote_idx, quote)
            if _quote_open_raw then
                table.insert(_quote_spans, { open = _quote_open_raw, close = nil })
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
                quotes        = #_quote_spans > 0 and _quote_spans or nil,
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
            if key == _IS_PREFIX then
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
    local defs = _build_map(schema)
    local hls  = {}

    for _, token in ipairs(_tokenize(raw)) do
        if token.colon_raw_pos then
            local s0  = token.start - 1
            local e0  = token.finish
            local key = token.text:sub(1, token.colon_pos - 1)
            local val = token.text:sub(token.colon_pos + 1)
            if key == _IS_PREFIX then
                local def = defs[val]
                if def and def.type == "boolean" then
                    table.insert(hls, { start = s0,                        finish = s0 + token.colon_raw_pos, hl = "Keyword" })
                    table.insert(hls, { start = s0 + token.colon_raw_pos, finish = e0,                        hl = "Special" })
                end
            else
                local def = defs[key]
                if def and def.type == "value" then
                    table.insert(hls, { start = s0,                        finish = s0 + token.colon_raw_pos, hl = "Keyword" })
                    if #val > 0 then
                        table.insert(hls, { start = s0 + token.colon_raw_pos, finish = e0,                        hl = "String"  })
                    end
                end
            end
        end
        if token.quotes then
            local s0 = token.start - 1
            for _, q in ipairs(token.quotes) do
                if q.close then
                    -- properly closed pair: highlight both delimiter chars
                    table.insert(hls, { start = s0 + q.open - 1,  finish = s0 + q.open,  hl = "Delimiter" })
                    table.insert(hls, { start = s0 + q.close - 1, finish = s0 + q.close, hl = "Delimiter" })
                end
            end
        end
    end

    return hls
end

---@param schema      keystone.queryflags.FlagDef[]
---@param line        string
---@param cursor_byte integer  -- 0-indexed byte offset from nvim_win_get_cursor
---@param auto        boolean? -- when true, only complete inside an in-progress flag (a "key:" token)
---@return keystone.queryflags.Completions?
function M.get_completions(schema, line, cursor_byte, auto)
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
        -- a leading quote marks an in-progress quoted value; drop it for matching
        -- (the inserted completion re-wraps the value in quotes as needed).
        local partial = current_word:sub(colon + 1):gsub("^[\"']", "")
        if prefix == _IS_PREFIX then
            local items = {}
            for _, def in ipairs(schema) do
                if def.type == "boolean" and vim.startswith(def.name, partial) then
                    table.insert(items, {
                        word = _IS_PREFIX .. ":" .. def.name,
                        abbr = def.name,
                        menu = def.desc or "[flag]",
                    })
                end
            end
            return #items > 0 and { startcol = word_start_1, items = items } or nil
        end
        local def = _build_map(schema)[prefix]
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

    -- A bare word could be query text; only offer flag-name suggestions on an
    -- explicit (non-auto) trigger.
    if auto then return nil end

    local items       = {}
    local has_boolean = false
    for _, def in ipairs(schema) do
        if def.type == "value" and vim.startswith(def.name, current_word) then
            table.insert(items, {
                word = def.name .. ":",
                abbr = def.name,
                menu = def.desc or "[filter]",
            })
        elseif def.type == "boolean" then
            has_boolean = true
        end
    end
    if has_boolean and vim.startswith(_IS_PREFIX, current_word) then
        table.insert(items, {
            word = _IS_PREFIX .. ":",
            abbr = _IS_PREFIX .. ":",
            menu = "[flag]",
        })
    end
    return #items > 0 and { startcol = word_start_1, items = items } or nil
end

return M
