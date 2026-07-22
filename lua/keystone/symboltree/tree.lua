local M = {}

local config   = require("keystone.symboltree").config
local fixedwin = require("keystone.tk.fixedwin")

local _KEY_MARKER = "Keystone_symboltreewin"

local _tree ---@type keystone.SymbolTree?

---@return number?
local function _get_win()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
        local ok, val = pcall(function() return vim.w[win][_KEY_MARKER] end)
        if ok and val == true then return win end
    end
    return nil
end

-- Set a window-local option without leaking it into nvim's hidden global default
-- (see keystone.tk.fixedwin for the gotcha this avoids).
---@param win integer
---@param opt string
---@param val any
local function _setlocal(win, opt, val)
    vim.api.nvim_set_option_value(opt, val, { win = win, scope = "local" })
end

local function _open()
    if _get_win() then return end

    if not _tree then
        local SymbolTree = require("keystone.symboltree.SymbolTree")
        _tree = SymbolTree:new({
            track_cursor  = config.track_cursor,
            auto_expand   = config.auto_expand,
            show_detail   = config.show_detail,
            exclude_kinds = config.exclude_kinds,
            debounce_ms   = config.debounce_ms,
        })
    end

    _tree:create_buffer()
    local bufnr = _tree:get_bufnr()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    -- A width-pinned split on the far right. fixedwin tracks the ratio as the
    -- user resizes and re-pins it across layout/editor changes; persist the
    -- last-known ratio so reopening the tree keeps the user's chosen width.
    local win = fixedwin.create_fixed_win("width", config.width_ratio or 0.2, function(ratio)
        config.width_ratio = ratio
    end, { pos = "topleft" })

    vim.w[win][_KEY_MARKER] = true

    local bufname = "keystone://" .. bufnr .. "/Symbol Tree"
    vim.api.nvim_buf_set_name(bufnr, bufname)
    vim.api.nvim_win_set_buf(win, bufnr)

    _setlocal(win, "wrap", false)
    _setlocal(win, "spell", false)
    _setlocal(win, "winfixbuf", true)
    _setlocal(win, "winfixheight", true)
end

function M.toggle()
    local win = _get_win()
    if win then
        vim.api.nvim_win_close(win, false)
    else
        _open()
    end
end

function M.open()
    _open()
end

function M.close()
    local win = _get_win()
    if win then
        vim.api.nvim_win_close(win, false)
    end
end

function M.is_visible()
    return _get_win() ~= nil
end

return M
