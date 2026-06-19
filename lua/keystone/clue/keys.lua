--- Keymap collection, tokenization and prefix matching for `keystone.clue`.
---
--- Everything works in "token space": a key sequence is decoded into a list of
--- readable tokens (via `keytrans`), e.g. `<leader>fg` -> `{ " ", "f", "g" }`
--- and `<C-w>v` -> `{ "<C-W>", "v" }`. Both keymap left-hand sides and live
--- keypresses are normalized the same way, so prefix matching is a plain
--- token-list comparison.
local M = {}

--- Maps tagged with this `desc` are `keystone.clue`'s own trigger keymaps and
--- are filtered out of the collected set, otherwise a trigger could match
--- itself and recurse.
M.TRIGGER_DESC = "keystone.clue:trigger"

--- A normalized keymap entry.
---@class keystone.clue.Map
---@field lhsraw   string raw byte form of the left-hand side
---@field tokens   string[] readable token list
---@field desc     string?
---@field rhs      string?
---@field callback function?
---@field expr      integer?
---@field noremap   integer?

--- Expand `<leader>`/`<localleader>` then translate termcodes to raw bytes.
---@param keys string
---@return string
function M.to_raw(keys)
    local leader = vim.g.mapleader
    local localleader = vim.g.maplocalleader
    leader = (leader == nil or leader == "") and "\\" or tostring(leader)
    localleader = (localleader == nil or localleader == "") and "\\" or tostring(localleader)
    -- escape `%` so the replacement is treated literally by gsub
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

--- Decode a raw byte sequence into readable tokens.
---@param raw string
---@return string[]
function M.tokenize(raw)
    return _split_tokens(vim.fn.keytrans(raw))
end

--- Decode a single keypress (from `getcharstr`) into one token.
---@param ch string
---@return string
function M.key_token(ch)
    return vim.fn.keytrans(ch)
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
---@return keystone.clue.Map?
local function _normalize(map)
    if map.desc == M.TRIGGER_DESC then
        return nil
    end
    local lhsraw = map.lhsraw
    if not lhsraw or lhsraw == "" then
        lhsraw = vim.api.nvim_replace_termcodes(map.lhs, true, true, true)
    end
    local tokens = M.tokenize(lhsraw)
    if #tokens == 0 then
        return nil
    end
    return {
        lhsraw = lhsraw,
        tokens = tokens,
        desc = map.desc,
        rhs = map.rhs,
        callback = map.callback,
        expr = map.expr,
        noremap = map.noremap,
    }
end

--- Collect global + buffer-local maps for `mode`. Buffer-local maps override
--- global ones with the same left-hand side.
---@param mode string
---@return keystone.clue.Map[]
function M.collect(mode)
    local list = {}
    local seen = {} ---@type table<string, integer>

    local function add(raw_maps)
        for _, raw in ipairs(raw_maps) do
            local m = _normalize(raw)
            if m then
                local at = seen[m.lhsraw]
                if at then
                    list[at] = m
                else
                    table.insert(list, m)
                    seen[m.lhsraw] = #list
                end
            end
        end
    end

    for _, qmode in ipairs(_modes_to_query(mode)) do
        add(vim.api.nvim_get_keymap(qmode))
    end
    -- buffer-local last so they win
    for _, qmode in ipairs(_modes_to_query(mode)) do
        add(vim.api.nvim_buf_get_keymap(0, qmode))
    end

    return list
end

--- Whether `tokens` begins with `prefix`.
---@param tokens string[]
---@param prefix string[]
---@return boolean
function M.starts_with(tokens, prefix)
    if #tokens < #prefix then
        return false
    end
    for i = 1, #prefix do
        if tokens[i] ~= prefix[i] then
            return false
        end
    end
    return true
end

--- The map whose tokens exactly equal `prefix`, if any.
---@param maps keystone.clue.Map[]
---@param prefix string[]
---@return keystone.clue.Map?
function M.exact_map(maps, prefix)
    for _, m in ipairs(maps) do
        if #m.tokens == #prefix and M.starts_with(m.tokens, prefix) then
            return m
        end
    end
    return nil
end

--- Whether any map extends `prefix` with at least one more token.
---@param maps keystone.clue.Map[]
---@param prefix string[]
---@return boolean
function M.has_children(maps, prefix)
    for _, m in ipairs(maps) do
        if #m.tokens > #prefix and M.starts_with(m.tokens, prefix) then
            return true
        end
    end
    return false
end

--- Number of maps whose tokens begin with `prefix` (includes an exact match).
---@param maps keystone.clue.Map[]
---@param prefix string[]
---@return integer
function M.count_prefix(maps, prefix)
    local count = 0
    for _, m in ipairs(maps) do
        if M.starts_with(m.tokens, prefix) then
            count = count + 1
        end
    end
    return count
end

---@param map keystone.clue.Map
---@return string
local function _leaf_label(map)
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

--- A single line of the clue window.
---@class keystone.clue.Entry
---@field key      string readable next token
---@field desc     string
---@field is_group boolean whether pressing it leads to further keys

--- Build the clue entries shown for `prefix`: one per distinct next token.
---@param maps keystone.clue.Map[]
---@param prefix string[]
---@param groups table<string, string>? normalized group descriptions (token-join -> desc)
---@return keystone.clue.Entry[]
function M.clues(maps, prefix, groups)
    local plen = #prefix
    local by_next = {} ---@type table<string, {key:string, count:integer, group:boolean, leaf:keystone.clue.Map?}>
    local order = {}

    for _, m in ipairs(maps) do
        if #m.tokens > plen and M.starts_with(m.tokens, prefix) then
            local nt = m.tokens[plen + 1]
            local e = by_next[nt]
            if not e then
                e = { key = nt, count = 0, group = false, leaf = nil }
                by_next[nt] = e
                table.insert(order, nt)
            end
            e.count = e.count + 1
            if #m.tokens == plen + 1 then
                e.leaf = m
            else
                e.group = true
            end
        end
    end

    local prefix_str = table.concat(prefix)
    local entries = {} ---@type keystone.clue.Entry[]
    for _, nt in ipairs(order) do
        local e = by_next[nt]
        local is_group = e.group or e.count > 1
        local desc
        if is_group then
            local configured = groups and groups[prefix_str .. nt]
            desc = "+" .. (configured or tostring(e.count))
        else
            desc = _leaf_label(e.leaf)
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
