local M = {}

---A source for a value flag's completion candidates: either a
---`vim.fn.getcompletion()` type (e.g. "file", "dir", "buffer", "color"), or a
---function returning candidates for the partial value typed so far.
---@alias keystone.queryflags.CompleteSpec string|fun(partial:string):string[]

---@class keystone.queryflags.FlagDef
---@field name     string
---@field type     "boolean"|"value"
---@field multi    boolean?   -- allow multiple occurrences (type=value only)
---@field allow_empty boolean? -- keep an empty value instead of dropping the flag (type=value only)
---@field values   string[]?  -- known static values offered in completion (type=value only)
---@field complete keystone.queryflags.CompleteSpec?  -- dynamic value completion source (type=value only)
---@field desc     string?    -- shown in the completion menu

---@class keystone.queryflags.ParseResult
---@field query string  -- the literal query (all non-flag tokens, joined by space)
---@field flags table   -- {[name] = true | string | string[]}

---@class keystone.queryflags.Completions
---@field startcol integer  -- 1-indexed column for vim.fn.complete()
---@field items    table[]

local function _build_map(schema)
    local m = {}
    for _, def in ipairs(schema) do m[def.name] = def end
    return m
end

-- Syntax:
--
--   <token> <token> ...
--
-- The input is a flat list of whitespace-separated tokens with no separator;
-- flags and query text may appear in any order. Each token is classified:
--   boolean flag:  "is:flagname" → flags.flagname = true  (matching a boolean def)
--   value flag:    "key:value"   → flags.key = value      (or string[] if multi)
--   anything else: query text
-- The query is every non-flag token joined back together with single spaces.
-- Boolean flags have no standalone form — "flagname" alone is always query
-- text; the "is:" prefix is what distinguishes a flag from a query word.
--
-- Quoting (' or ") lets a token contain spaces, and forces a token to be
-- literal query text even when it would otherwise look like a flag:
--   'path:"foo bar"' → value flag whose value contains a space
--   '"is:fixed"'     → query text "is:fixed" (the key is quoted, so not a flag)
--   '"path:foo"'     → query text "path:foo" (the key is quoted, so not a flag)
-- An unterminated quote runs to the end of the token.

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

        local tok_start       = i
        local chars           = {}
        local colon_pos       = nil
        local colon_raw_pos   = nil
        local quote           = nil -- active quote char while inside a quoted span
        local quote_idx       = nil -- index in `chars` where the active quote opened
        local _quote_spans    = {}
        local _quote_open_raw = nil -- raw-relative 1-indexed position of the active opening quote

        while i <= len do
            local c = str:sub(i, i)
            if quote then
                -- inside a quoted span: whitespace is literal, matching quote
                -- chars are stripped from `text` but remain in `raw`.
                if c == quote then
                    table.insert(_quote_spans, { open = _quote_open_raw, close = i - tok_start + 1 })
                    _quote_open_raw = nil
                    quote           = nil
                    quote_idx       = nil
                else
                    table.insert(chars, c)
                end
                i = i + 1
            elseif c:match("%s") then
                break
            elseif c == '"' or c == "'" then
                -- opening quote: allows whitespace within the token
                _quote_open_raw = i - tok_start + 1
                quote           = c
                quote_idx       = #chars + 1
                i               = i + 1
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

-- Classify a single token against the flag schema.
--
-- A value flag is a "key:value" token whose key is unquoted and matches a value
-- def; the value may be quoted to contain spaces. A boolean flag is an
-- "is:flagname" token whose flagname matches a boolean def — there is no
-- standalone form. Everything else is query text. Quoting the key part forces
-- a token to be query text even if it looks like a flag.
---@param defs  table<string, keystone.queryflags.FlagDef>
---@param token keystone.queryflags.Token
---@return "boolean"|"value"|nil kind, string? key, string? value
local function _classify(defs, token)
    local colon = token.colon_pos
    if not colon or colon <= 1 then return nil end

    -- "key:value" shape; only a flag when the key is not quoted.
    local key_quoted = false
    if token.quotes then
        for _, q in ipairs(token.quotes) do
            if q.open <= (token.colon_raw_pos or 0) then
                key_quoted = true
                break
            end
        end
    end
    if key_quoted then return nil end

    local key  = token.text:sub(1, colon - 1)
    local rest = token.text:sub(colon + 1)

    if key == "is" then
        local def = defs[rest]
        if def and def.type == "boolean" then
            return "boolean", rest, nil
        end
        return nil
    end

    local def = defs[key]
    if def and def.type == "value" then
        return "value", key, rest
    end
    return nil
end

---@param schema keystone.queryflags.FlagDef[]
---@param raw    string
---@return keystone.queryflags.ParseResult
function M.parse(schema, raw)
    local defs   = _build_map(schema)
    local flags  = {}
    local tokens = _tokenize(raw)
    local parts  = {}

    for _, token in ipairs(tokens) do
        local kind, key, value = _classify(defs, token)
        if kind == "value" and key then
            local def = defs[key]
            if value and (value ~= "" or def.allow_empty) then
                if def.multi then
                    flags[key] = flags[key] or {}
                    table.insert(flags[key], value)
                else
                    flags[key] = value
                end
            end
        elseif kind == "boolean" and key then
            flags[key] = true
        else
            parts[#parts + 1] = token.text
        end
    end

    return { query = table.concat(parts, " "), flags = flags }
end

---@param schema keystone.queryflags.FlagDef[]
---@param raw    string
---@return {start:integer, finish:integer, hl:string}[]
function M.highlight(schema, raw)
    local defs   = _build_map(schema)
    local hls    = {}
    local tokens = _tokenize(raw)

    for _, token in ipairs(tokens) do
        local kind, _, value = _classify(defs, token)
        local s0 = token.start - 1
        local e0 = token.finish

        if kind == "value" then
            table.insert(hls, { start = s0, finish = s0 + token.colon_raw_pos, hl = "Keyword" })
            if value and #value > 0 then
                table.insert(hls, { start = s0 + token.colon_raw_pos, finish = e0, hl = "String" })
            end
        elseif kind == "boolean" then
            table.insert(hls, { start = s0, finish = e0, hl = "Keyword" })
        end

        -- Quote chars are highlighted wherever they appear: around a value
        -- flag's value (e.g. path:"foo bar") and in plain query text where a
        -- quote escapes a flag-looking token into literal text (e.g. "is:fixed").
        -- Inserted last so they win over the value's String/Keyword highlight.
        if token.quotes then
            for _, q in ipairs(token.quotes) do
                if q.close then
                    table.insert(hls, { start = s0 + q.open - 1, finish = s0 + q.open, hl = "Delimiter" })
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

    local before       = line:sub(1, cursor_byte)
    local tokens       = _tokenize(before)

    local last         = tokens[#tokens]
    local word_start_1 = #before + 1
    local current_word = ""
    if last and last.finish == #before then
        word_start_1 = last.start
        current_word = last.text
    end

    local colon = last and last.finish == #before and last.colon_pos
    if colon and colon > 1 then
        local prefix  = current_word:sub(1, colon - 1)
        local partial = current_word:sub(colon + 1):gsub("^[\"']", "")

        local defs    = _build_map(schema)

        -- Case 1: Inside an "is:<partial_boolean_flag>" block
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
        end

        -- Case 2: Inside a "value_flag:<partial_value>" block. Candidates come
        -- from the flag's static `values` and/or its dynamic `complete` source
        -- (e.g. file/dir completion); the value is quoted when it contains a space.
        local def = defs[prefix]
        if def and def.type == "value" and (def.values or def.complete) then
            local items = {}
            local function add(v)
                local word = v:find("%s")
                    and (prefix .. ':"' .. v .. '"')
                    or (prefix .. ":" .. v)
                table.insert(items, { word = word, abbr = v })
            end

            for _, v in ipairs(def.values or {}) do
                if vim.startswith(v, partial) then add(v) end
            end

            if def.complete then
                local cands
                if type(def.complete) == "function" then
                    cands = def.complete(partial)
                else
                    -- getcompletion already filters by `partial`; trust its output.
                    local ok, res = pcall(vim.fn.getcompletion, partial, def.complete)
                    cands = ok and res or nil
                end
                for _, v in ipairs(cands or {}) do add(v) end
            end

            return #items > 0 and { startcol = word_start_1, items = items } or nil
        end
        return nil
    end

    -- A bare word could be query text; only offer flag-name suggestions on an
    -- explicit (non-auto) trigger.
    if auto then return nil end

    local items = {}
    -- If they have already started typing "is", suggest "is:" right away
    if vim.startswith("is:", current_word) and #current_word > 0 then
        table.insert(items, {
            word = "is:",
            abbr = "is:",
            menu = "[boolean prefix]",
        })
    end

    for _, def in ipairs(schema) do
        if def.type == "value" and vim.startswith(def.name, current_word) then
            table.insert(items, {
                word = def.name .. ":",
                abbr = def.name,
                menu = def.desc or "[filter]",
            })
        elseif def.type == "boolean" then
            -- Boolean flags are generated dynamically behind "is:<name>".
            -- We can suggest the full "is:<name>" string matching current_word.
            local full_bool = "is:" .. def.name
            if vim.startswith(full_bool, current_word) then
                table.insert(items, {
                    word = full_bool,
                    abbr = full_bool,
                    menu = def.desc or "[flag]",
                })
            end
        end
    end
    return #items > 0 and { startcol = word_start_1, items = items } or nil
end

return M
