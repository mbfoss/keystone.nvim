local M = {}

local config   = require("keystone.filetree").config
local fixedwin = require("keystone.util.fixedwin")

local _KEY_MARKER = "Keystone_filetreewin"

local _tree ---@type keystone.FileTree?

---@return number?
local function _get_win()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
        local ok, val = pcall(function() return vim.w[win][_KEY_MARKER] end)
        if ok and val == true then return win end
    end
    return nil
end

-- Set a window-local option without leaking it into nvim's hidden global default
-- (see keystone.util.fixedwin for the gotcha this avoids).
---@param win integer
---@param opt string
---@param val any
local function _setlocal(win, opt, val)
    vim.api.nvim_set_option_value(opt, val, { win = win, scope = "local" })
end

---@return keystone.FileTree
local function _get_tree()
    if not _tree then
        local FileTree = require("keystone.filetree.FileTree")
        _tree = FileTree:new({
            track_current_file = {
                enabled = config.follow_current_buffer == true,
                auto_collapse_others = true,
            },
        })
    end
    return _tree
end

local function _open()
    -- Already visible: re-reveal so the command still syncs the tree to the
    -- current buffer (a no-op when the current buffer isn't a real file).
    if _get_win() then
        if _tree then _tree:reveal_current_file(true) end
        return
    end

    local tree = _get_tree()
    tree:create_buffer()
    local bufnr = tree:get_bufnr()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local filename = vim.api.nvim_buf_get_name(0)

    -- A split pinned to a ratio of the editor size: width for left/right, height
    -- for top/bottom. fixedwin tracks the ratio as the user resizes and re-pins it
    -- across layout/editor changes; persist the last-known ratio so reopening the
    -- tree keeps the user's chosen size.
    local position = config.position or "left"
    local vertical = position == "left" or position == "right"
    local pos = (position == "left" or position == "top") and "topleft" or "botright"
    local win
    if vertical then
        win = fixedwin.create_fixed_win(bufnr, {
            axis = "width", ratio = config.width_ratio or 0.2, pos = pos,
            on_delete = function(ratio) config.width_ratio = ratio end,
        })
    else
        win = fixedwin.create_fixed_win(bufnr, {
            axis = "height", ratio = config.height_ratio or 0.3, pos = pos,
            on_delete = function(ratio) config.height_ratio = ratio end,
        })
    end

    vim.w[win][_KEY_MARKER] = true

    local bufname = "keystone://" .. bufnr .. "/file-tree"
    vim.api.nvim_buf_set_name(bufnr, bufname)

    _setlocal(win, "wrap", false)
    _setlocal(win, "spell", false)
    _setlocal(win, "winfixbuf", true)

    tree:reveal(filename, true)
end

function M.toggle()
    local win = _get_win()
    if win then
        vim.api.nvim_win_close(win, false)
    else
        _open()
    end
end

--- Open the tree, first setting its root to `dir` when given.
---@param dir string?
function M.open(dir)
    if dir then
        _get_tree():set_root(dir)
    end
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
