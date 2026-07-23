local M = {}

local config   = require("keystone.calltree").config
local fixedwin = require("keystone.tk.fixedwin")

local _KEY_MARKER = "Keystone_calltreewin"

local _tree ---@type keystone.CallTree?

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

---@return keystone.CallTree
local function _get_tree()
    if not _tree then
        local CallTree = require("keystone.calltree.CallTree")
        _tree = CallTree:new({
            direction        = config.direction,
            show_detail      = config.show_detail,
            auto_expand_root = config.auto_expand_root,
        })
    end
    return _tree
end

---@return integer? win
local function _open_win()
    local existing = _get_win()
    if existing then return existing end

    local tree = _get_tree()
    tree:create_buffer()
    local bufnr = tree:get_bufnr()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    -- A width-pinned split. fixedwin tracks the ratio as the user resizes and
    -- re-pins it across layout/editor changes; persist the last-known ratio so
    -- reopening the tree keeps the user's chosen width.
    local win = fixedwin.create_fixed_win("width", config.width_ratio or 0.25, function(ratio)
        config.width_ratio = ratio
    end, { pos = config.position == "right" and "botright" or "topleft" })

    vim.w[win][_KEY_MARKER] = true

    local bufname = "keystone://" .. bufnr .. "/Call Tree"
    vim.api.nvim_buf_set_name(bufnr, bufname)
    vim.api.nvim_win_set_buf(win, bufnr)

    _setlocal(win, "wrap", false)
    _setlocal(win, "spell", false)
    _setlocal(win, "winfixbuf", true)
    _setlocal(win, "winfixheight", true)

    return win
end

--- Open the tree on the symbol under the cursor, re-rooting an already-open one.
--- Must be called from the source window, since that cursor is what names the
--- symbol; called from the tree itself it only applies `direction`, leaving the
--- root alone.
---@param direction keystone.calltree.Direction? overrides the configured direction
function M.open(direction)
    local source_buf = vim.api.nvim_get_current_buf()
    local source_win = vim.api.nvim_get_current_win()

    if source_win == _get_win() then
        if direction then _get_tree():set_direction(direction) end
        return
    end

    if not _open_win() then return end

    _get_tree():show_from_cursor(source_buf, source_win, direction)
end

function M.close()
    local win = _get_win()
    if win then
        vim.api.nvim_win_close(win, false)
    end
end

--- Close the tree if it is open, otherwise open it on the symbol under the
--- cursor.
function M.toggle()
    if _get_win() then
        M.close()
    else
        M.open()
    end
end

--- Swap between incoming and outgoing calls, keeping the current root. Opens the
--- tree on the symbol under the cursor if it is not showing yet.
function M.swap_direction()
    if not _get_win() then
        M.open(_get_tree():get_direction() == "incoming" and "outgoing" or "incoming")
        return
    end
    _get_tree():swap_direction()
end

function M.refresh()
    if not _get_win() then return end
    _get_tree():refresh()
end

function M.is_visible()
    return _get_win() ~= nil
end

return M
