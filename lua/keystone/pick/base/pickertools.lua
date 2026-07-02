local M = {}

local fsutil = require("keystone.tk.fsutil")

---@param text string The final string to be shown
---@param positions integer[] Matched indices
---@param hl_group string? Optional override for the match highlight
---@return table[] chunks
local function _build_highlight_chunks(text, positions, hl_group)
    if not positions or #positions == 0 then
        return { { text } }
    end

    local hl = hl_group or "Todo"
    local chunks = {}
    local pos_map = {}
    for _, p in ipairs(positions) do pos_map[p] = true end

    local current_chunk = ""
    local last_was_match = pos_map[1] or false
    local nchars = vim.fn.strchars(text)

    for i = 1, nchars do
        local char = vim.fn.strcharpart(text, i - 1, 1)
        local is_match = pos_map[i] or false
        if is_match ~= last_was_match then
            table.insert(chunks, last_was_match and { current_chunk, hl } or { current_chunk })
            current_chunk = char
            last_was_match = is_match
        else
            current_chunk = current_chunk .. char
        end
    end

    if current_chunk ~= "" then
        table.insert(chunks, last_was_match and { current_chunk, hl } or { current_chunk })
    end
    return chunks
end

---@param text string
---@param positions integer[]? 1-based matched char positions
---@return table[] chunks
function M.highlight_chunks(text, positions)
    return _build_highlight_chunks(text, positions or {})
end

-- ── Matcher (case-insensitive) ───────────────────────────────────────────────
-- match_label only knows how to *find* `query` in `text`; it never reasons about
-- case. Case sensitivity is layered on top separately by the gate below.

---@param text string What we match against
---@param query string User input
---@return {score:number,chunks:string[][]}?
function M.match_label(text, query)
    if query == "" then
        return { score = 0, chunks = _build_highlight_chunks(text, {}) }
    end
    -- matchfuzzypos is smart-case (a lowercase query char matches either case), so
    -- a lowercased query yields plain case-insensitive fuzzy matching.
    local result = vim.fn.matchfuzzypos({ text }, query:lower())
    if #result[1] == 0 then return nil end
    local positions = {}
    for _, p in ipairs(result[2][1]) do
        positions[#positions + 1] = p + 1 -- matchfuzzypos is 0-based; chunks want 1-based
    end
    return { score = result[3][1], chunks = _build_highlight_chunks(text, positions) }
end

-- ── Case gate ────────────────────────────────────────────────────────────────
-- The case concept, standalone: given the same text/query as match_label, does a
-- *case-exact* subsequence exist, and where? Returns the 1-based char positions
-- of that match (for highlighting) or nil.

---@param text string
---@param query string
---@return integer[]?
function M.case_subseq(text, query)
    -- Greedy earliest matching is complete: if any case-exact subsequence exists
    -- it finds one, so there are no false negatives.
    local positions = {}
    local tn        = vim.fn.strchars(text)
    local qn        = vim.fn.strchars(query)
    local qi        = 0
    for ti = 0, tn - 1 do
        if qi >= qn then break end
        if vim.fn.strcharpart(text, ti, 1) == vim.fn.strcharpart(query, qi, 1) then
            positions[#positions + 1] = ti + 1
            qi = qi + 1
        end
    end
    if qi < qn then return nil end
    return positions
end

-- Match a glob `[...]` character class against a single character.
--
-- `j` is the 1-indexed position of the first char *inside* the class (i.e. just
-- after the opening `[`). Supports `!`/`^` negation, `a-z` ranges, `\` escapes
-- and a literal leading `]`. Returns `matched, next_index` where `next_index`
-- points just past the closing `]`, or `nil` when the class is unterminated (in
-- which case the caller should treat `[` as a literal character).
---@param pat string
---@param j integer
---@param ch string
---@return boolean? matched, integer? next_index
local function _class_match(pat, j, ch)
    local plen   = #pat
    local negate = false
    local c0     = pat:sub(j, j)
    if c0 == "!" or c0 == "^" then
        negate = true
        j      = j + 1
    end

    local matched = false
    local first   = true -- a `]` in first position is a literal member
    while j <= plen do
        local c = pat:sub(j, j)
        if c == "]" and not first then
            if negate then matched = not matched end
            return matched, j + 1
        end
        first = false

        if c == "\\" and j < plen then
            if pat:sub(j + 1, j + 1) == ch then matched = true end
            j = j + 2
        elseif pat:sub(j + 1, j + 1) == "-"
            and pat:sub(j + 2, j + 2) ~= ""
            and pat:sub(j + 2, j + 2) ~= "]" then
            local lo, hi = c, pat:sub(j + 2, j + 2)
            if ch >= lo and ch <= hi then matched = true end
            j = j + 3
        else
            if c == ch then matched = true end
            j = j + 1
        end
    end

    return nil -- unterminated `[`
end

-- Match a single glob segment (no `/`) against a single path component.
--
-- `*` matches any run of characters, `?` any single character, `[...]` a class,
-- `\` escapes the next character; everything else is literal. Both indices are
-- 1-indexed. Path components never contain `/`, so neither `*` nor `?` can cross
-- a separator here — that is enforced by `_match_components` splitting on `/`.
---@param pat string
---@param pi integer
---@param str string
---@param ti integer
---@return boolean
local function _seg_match(pat, pi, str, ti)
    local plen, slen = #pat, #str
    while pi <= plen do
        local pc = pat:sub(pi, pi)
        if pc == "*" then
            -- collapse runs of `*` and try the remainder at every split point
            while pat:sub(pi, pi) == "*" do pi = pi + 1 end
            if pi > plen then return true end
            for k = ti, slen + 1 do
                if _seg_match(pat, pi, str, k) then return true end
            end
            return false
        elseif pc == "?" then
            if ti > slen then return false end
            pi, ti = pi + 1, ti + 1
        elseif pc == "[" then
            if ti > slen then return false end
            local m, next_pi = _class_match(pat, pi + 1, str:sub(ti, ti))
            if m == nil then
                if str:sub(ti, ti) ~= "[" then return false end
                pi, ti = pi + 1, ti + 1
            else
                if not m then return false end
                ---@cast next_pi -nil
                pi, ti = next_pi, ti + 1
            end
        elseif pc == "\\" and pi < plen then
            if str:sub(ti, ti) ~= pat:sub(pi + 1, pi + 1) then return false end
            pi, ti = pi + 2, ti + 1
        else
            if str:sub(ti, ti) ~= pc then return false end
            pi, ti = pi + 1, ti + 1
        end
    end
    return ti > slen
end

-- Match a list of glob segments against a list of path components, honouring
-- `**` (globstar): a leading or interior `**` matches zero or more components,
-- while a trailing `**` matches one or more (everything *inside* a directory,
-- per gitignore's `abc/**`).
---@param gsegs string[]
---@param gi integer
---@param psegs string[]
---@param pj integer
---@return boolean
local function _match_components(gsegs, gi, psegs, pj)
    while gi <= #gsegs do
        if gsegs[gi] == "**" then
            if gi == #gsegs then
                return pj <= #psegs
            end
            for k = pj, #psegs + 1 do
                if _match_components(gsegs, gi + 1, psegs, k) then return true end
            end
            return false
        end
        if pj > #psegs then return false end
        if not _seg_match(gsegs[gi], 1, psegs[pj], 1) then return false end
        gi, pj = gi + 1, pj + 1
    end
    return pj > #psegs
end

--- Match a path against a ripgrep/gitignore-style glob.
---
--- Semantics mirror ripgrep `--glob` (case-sensitive; pass `nocase` for the
--- `--iglob` equivalent):
---   * `*`      matches any run of characters except `/`
---   * `?`      matches any single character except `/`
---   * `[...]`  a character class (`[!...]`/`[^...]` negate, `a-z` ranges)
---   * `**`     as a whole path component matches zero or more directories;
---              a trailing `/**` matches everything inside a directory
---   * a pattern with no `/` matches the basename at any depth (e.g. `*.txt`),
---     while a pattern containing `/` is anchored to the path root (`src/*.txt`)
---@param pattern string  rg-style glob (e.g. "*.txt", "**/src/**", "src/*.lua")
---@param relpath string  relative file path (e.g. "lua/keystone/util/foo.lua")
---@param nocase boolean? when true, match case-insensitively (like `rg --iglob`)
---@return boolean
function M.match_glob(pattern, relpath, nocase)
    if nocase then
        pattern = pattern:lower()
        relpath = relpath:lower()
    end

    local trimmed = pattern:gsub("/+$", "") -- a trailing `/` only marks directories
    if trimmed == "" then return false end

    local pat
    if trimmed:find("/", 1, true) then
        pat = trimmed:gsub("^/+", "") -- a leading `/` just anchors to the root
    else
        pat = "**/" .. trimmed        -- no separator → match the basename anywhere
    end

    local gsegs = vim.split(pat, "/", { plain = true })
    local psegs = vim.split(relpath, "/", { plain = true })
    return _match_components(gsegs, 1, psegs, 1)
end

---@type keystone.Picker.AsyncPreviewLoader
function M.file_preview(data, _, callback)
    local _max_size = 10124 * 10124
    local _filepath = data.filepath
    if not _filepath or _filepath == "" then
        callback({})
        return
    end
    if not fsutil.file_exists(_filepath) then
        callback({ error_msg = "Invalid file path: " .. tostring(_filepath) })
        return
    end
    local _cancelled = false
    local _cancel_fn
    vim.uv.fs_stat(_filepath, vim.schedule_wrap(function(stat_err, stat)
        if _cancelled then return end
        if stat_err or not stat then
            callback({ error_msg = stat_err })
            return
        end
        if stat.size > _max_size then
            callback({ error_msg = "Maximum file size exceeded" })
            return
        end
        _cancel_fn = fsutil.async_load_text_file(_filepath, { timeout = 3000 },
            function(load_err, content)
                callback({
                    content   = content,
                    filepath  = _filepath,
                    pos       = data.lnum and { data.lnum, data.col or 0 } or nil,
                    error_msg = load_err,
                })
            end)
    end))
    return function()
        _cancelled = true
        if _cancel_fn then _cancel_fn() end
    end
end

---@param name string
---@param opts {max_entries:number?}?
---@return keystone.Picker.QueryHistoryProvider
function M.make_history_provider(name, opts)
    opts = opts or {}

    assert(type(name) == "string" and name:match("^[%w_]+$"), "invalid name")
    assert(not opts.max_entries or type(opts.max_entries) == "number")

    local dir = vim.fs.joinpath(vim.fn.stdpath("data"), "keystone")
    local file_path = vim.fs.joinpath(dir, "pickhist." .. name .. ".txt")
    local max_entries = opts.max_entries or 50
    ---@type keystone.Picker.QueryHistoryProvider
    local provider = {
        load = function()
            local hist = {}
            ---@type boolean,string
            local ok, lines = fsutil.read_content(file_path)
            if ok then
                hist = vim.split(lines, '\n')
            end
            return hist
        end,
        ---@param hist string[]
        store = function(hist)
            vim.fn.mkdir(dir, 'p')
            local start_idx = math.max(#hist - max_entries + 1, 1)
            local final_hist = {}
            for i = start_idx, #hist do
                local s = hist[i]
                assert(not s:match('\n'), "picker history item cannot contain \n")
                table.insert(final_hist, s)
            end
            fsutil.write_content(file_path, table.concat(final_hist, '\n'))
        end
    }

    return provider
end


return M
