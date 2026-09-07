--- Key-string helpers shared by the clue tree and engine.
---
--- Everything is canonicalised to the *keytrans* form (e.g. `<leader>f` becomes
--- `<Space>f`, ctrl-w becomes `<C-W>`).  This is the same form `vim.fn.keytrans`
--- returns for a character read from `getcharstr`, so tokens read at runtime
--- compare equal to tokens stored in the tree.
local M = {}

---@type table<string, string>
local _t_cache = {}

---@type table<string, string>
local _norm_cache = {}

---@type table<string, string>
local _norm_raw_cache = {}

---@type table<string, string[]>
local _split_cache = {}

--- Replace `<...>` notation with the raw byte sequence.
---@param str string
---@return string
function M.t(str)
    if _t_cache[str] == nil then
        _t_cache[str] = vim.api.nvim_replace_termcodes(str, true, true, true)
    end
    return _t_cache[str]
end

--- Normalise an lhs in `<...>` notation (e.g. `<leader>f`, `<C-w>s`) to
--- canonical keytrans form.
---@param lhs string
---@return string
function M.norm(lhs)
    if _norm_cache[lhs] == nil then
        _norm_cache[lhs] = vim.fn.keytrans(M.t(lhs))
    end
    return _norm_cache[lhs]
end

--- Normalise an already byte-encoded lhs (e.g. `nvim_get_keymap().lhsraw`) to
--- canonical keytrans form. Unlike `norm`, the bytes are *not* run through
--- `replace_termcodes` again: they already hold internal key codes, and
--- re-encoding mangles special keys (a `<C-T>`'s leading `0x80` would surface
--- as a stray `<80>` token in the popup).
---@param lhsraw string
---@return string
function M.norm_raw(lhsraw)
    if _norm_raw_cache[lhsraw] == nil then
        _norm_raw_cache[lhsraw] = vim.fn.keytrans(lhsraw)
    end
    return _norm_raw_cache[lhsraw]
end

--- Split a *normalised* string into individual key tokens, keeping `<...>`
--- chords as single tokens and treating multibyte characters as single tokens.
---@param norm_str string
---@return string[]
function M.split(norm_str)
    if _split_cache[norm_str] then
        return _split_cache[norm_str]
    end
    local ret = {} ---@type string[]
    local special = nil ---@type string?
    for _, byte in ipairs(vim.fn.str2list(norm_str)) do
        local char = vim.fn.nr2char(byte)
        if char == "<" then
            special = "<"
        elseif special then
            special = special .. char
            if char == ">" then
                ret[#ret + 1] = special == "<lt>" and "<" or special
                special = nil
            end
        else
            ret[#ret + 1] = char
        end
    end
    -- An unterminated "<" is a literal less-than; emit its chars verbatim.
    if special then
        for i = 1, #special do
            ret[#ret + 1] = special:sub(i, i)
        end
    end
    _split_cache[norm_str] = ret
    return ret
end

--- Map a user-facing mode letter to the mapmode used for lookups.
--- Visual/select `v` resolves to the `x` mapmode.
---@param mode string
---@return string
function M.spec_mode(mode)
    if mode == "v" then
        return "x"
    end
    return mode
end

return M
