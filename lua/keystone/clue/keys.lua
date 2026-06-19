--- Keymap collection and prefix matching for `keystone.clue`.
---
--- Matching is done in raw-byte space: `vim.on_key` hands us the physically
--- typed bytes, and `nvim_get_keymap` gives each mapping's `lhsraw` (raw bytes),
--- so a pending sequence is a prefix of a mapping iff its bytes are a byte-prefix
--- of the mapping's `lhsraw`. Because `on_key` reports one whole key per event,
--- byte boundaries always coincide with key boundaries.
---
--- Tokenization (via `keytrans`) is used only for *display* — turning the bytes
--- after the pending prefix into readable key labels.
local M = {}

--- Expand `<leader>`/`<localleader>` then translate termcodes to raw bytes.
---@param keys string
---@return string
function M.to_raw(keys)
    local leader = vim.g.mapleader
    local localleader = vim.g.maplocalleader
    leader = (leader == nil or leader == "") and "\\" or tostring(leader)
    localleader = (localleader == nil or localleader == "") and "\\" or tostring(localleader)
    keys = keys:gsub("<[lL]eader>", (leader:gsub("%%", "%%%%")))
    keys = keys:gsub("<[lL]ocalleader>", (localleader:gsub("%%", "%%%%")))
    return vim.api.nvim_replace_termcodes(keys, true, true, true)
end

--- Split a `keytrans`-translated string into single-key tokens. `keytrans`
--- escapes a literal `<` as `<lt>`, so every `<` begins a `<Name>` token.
---@param s string
---@return string[]
local function _split_tokens(s)
    local tokens = {}
    local i, n = 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c == "<" then
            local close = s:find(">", i + 1, true)
            if close then
                table.insert(tokens, s:sub(i, close))
                i = close + 1
            else
                table.insert(tokens, c)
                i = i + 1
            end
        else
            -- consume one UTF-8 character
            local b = s:byte(i)
            local len = 1
            if b >= 0xF0 then
                len = 4
            elseif b >= 0xE0 then
                len = 3
            elseif b >= 0xC0 then
                len = 2
            end
            table.insert(tokens, s:sub(i, i + len - 1))
            i = i + len
        end
    end
    return tokens
end

--- Decode raw bytes into readable key tokens (for display only).
---@param raw string
---@return string[]
function M.tokenize(raw)
    return _split_tokens(vim.fn.keytrans(raw))
end

---@param mode string
---@return string[]
local function _modes_to_query(mode)
    if mode == "x" or mode == "v" then
        return { "v", "x" }
    end
    return { mode }
end

---@param map table raw entry from nvim_get_keymap
---@return string
local function _lhsraw(map)
    local raw = map.lhsraw
    if raw == nil or raw == "" then
        raw = vim.api.nvim_replace_termcodes(map.lhs, true, true, true)
    end
    return raw
end

---@param map table
---@return string
local function _label(map)
    if map.desc and map.desc ~= "" then
        return map.desc
    end
    if map.callback then
        return "[lua]"
    end
    local rhs = map.rhs or ""
    rhs = rhs:gsub("^<[Cc]md>", ""):gsub("%s*<[Cc][Rr]>%s*$", ""):gsub("^:%s*", "")
    return rhs
end

--- A mapping (or virtual clue) reduced to what matching/display needs.
---@class keystone.clue.Map
---@field lhsraw string raw byte form of the left-hand side
---@field desc   string

--- A virtual clue entry supplied via config, describing a built-in key sequence
--- that has no mapping (e.g. `<C-w>v`).
---@class keystone.clue.Clue
---@field mode string
---@field keys string
---@field desc string

--- Collect mappings for `mode` plus any virtual `clues`, deduplicated by raw
--- left-hand side. Priority: buffer-local > global > virtual clue.
---@param mode string
---@param clues keystone.clue.Clue[]? virtual entries (already filtered to `mode`)
---@return keystone.clue.Map[]
function M.collect(mode, clues)
    local list = {} ---@type keystone.clue.Map[]
    local seen = {} ---@type table<string, boolean>

    local function add(lhsraw, desc)
        if lhsraw == nil or lhsraw == "" or seen[lhsraw] then
            return
        end
        seen[lhsraw] = true
        table.insert(list, { lhsraw = lhsraw, desc = desc })
    end

    -- buffer-local first so it wins over global
    for _, qmode in ipairs(_modes_to_query(mode)) do
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, qmode)) do
            add(_lhsraw(m), _label(m))
        end
    end
    for _, qmode in ipairs(_modes_to_query(mode)) do
        for _, m in ipairs(vim.api.nvim_get_keymap(qmode)) do
            add(_lhsraw(m), _label(m))
        end
    end
    for _, c in ipairs(clues or {}) do
        add(M.to_raw(c.keys), c.desc)
    end

    return list
end

--- Whether `lhsraw` begins with the byte prefix `raw`.
---@param lhsraw string
---@param raw string
---@return boolean
function M.starts_with(lhsraw, raw)
    return lhsraw:sub(1, #raw) == raw
end

--- Whether any map extends `raw` with at least one more byte.
---@param maps keystone.clue.Map[]
---@param raw string
---@return boolean
function M.has_children(maps, raw)
    local rlen = #raw
    for _, m in ipairs(maps) do
        if #m.lhsraw > rlen and m.lhsraw:sub(1, rlen) == raw then
            return true
        end
    end
    return false
end

--- The map whose left-hand side exactly equals `raw`, if any.
---@param maps keystone.clue.Map[]
---@param raw string
---@return keystone.clue.Map?
function M.exact(maps, raw)
    for _, m in ipairs(maps) do
        if m.lhsraw == raw then
            return m
        end
    end
    return nil
end

--- A single line of the clue window.
---@class keystone.clue.Entry
---@field key      string readable next key
---@field desc     string
---@field is_group boolean whether pressing it leads to further keys

--- Build the clue entries shown for the pending prefix `raw`: one per distinct
--- next key.
---@param maps keystone.clue.Map[]
---@param raw string
---@param groups table<string, string>? normalized group labels (token-join -> label)
---@return keystone.clue.Entry[]
function M.clues(maps, raw, groups)
    local rlen = #raw
    local by_next = {} ---@type table<string, {key:string, count:integer, group:boolean, leaf:keystone.clue.Map?}>
    local order = {}

    for _, m in ipairs(maps) do
        if #m.lhsraw > rlen and m.lhsraw:sub(1, rlen) == raw then
            local toks = M.tokenize(m.lhsraw:sub(rlen + 1))
            local nt = toks[1]
            if nt then
                local e = by_next[nt]
                if not e then
                    e = { key = nt, count = 0, group = false, leaf = nil }
                    by_next[nt] = e
                    table.insert(order, nt)
                end
                e.count = e.count + 1
                if #toks == 1 then
                    e.leaf = m
                else
                    e.group = true
                end
            end
        end
    end

    local prefix_join = table.concat(M.tokenize(raw))
    local entries = {} ---@type keystone.clue.Entry[]
    for _, nt in ipairs(order) do
        local e = by_next[nt]
        local is_group = e.group or e.count > 1
        local desc
        if is_group then
            local configured = groups and groups[prefix_join .. nt]
            desc = "+" .. (configured or tostring(e.count))
        else
            desc = e.leaf and e.leaf.desc or ""
        end
        table.insert(entries, { key = nt, desc = desc, is_group = is_group })
    end

    table.sort(entries, function(a, b)
        local ka, kb = a.key:lower(), b.key:lower()
        if ka == kb then
            return a.key < b.key
        end
        return ka < kb
    end)

    return entries
end

return M
