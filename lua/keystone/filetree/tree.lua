local M = {}

local config = require("keystone.filetree").config

local KEY_MARKER = "Keystone_filetreewin"
local _augroup = vim.api.nvim_create_augroup("keystone_filetree", { clear = true })

local _win = nil
local _buf = nil

local tree = nil

---@param win number
---@return boolean
local function is_valid(win)
    if not vim.api.nvim_win_is_valid(win) then return false end
    local ok, val = pcall(function()
        return vim.w[win][KEY_MARKER]
    end)
    return ok and val == true
end

local function create_tree_buffer()
    if not tree then
        local FileTree = require("keystone.filetree.FileTree")
        tree = FileTree:new()
    end
    return tree:get_compbuffer():get_or_create_buf()
end

local function apply_width()
    if not _win or not is_valid(_win) then return end
    local total = vim.o.columns
    local width = math.floor(total * (config.width_ratio or 0.2))
    vim.api.nvim_win_set_width(_win, width)
end

local function open()
    if _win and is_valid(_win) then
        return
    end

    _buf = create_tree_buffer()

    vim.cmd("topleft vnew")
    _win = vim.api.nvim_get_current_win()

    vim.w[_win][KEY_MARKER] = true

    vim.api.nvim_win_set_buf(_win, _buf)

    vim.wo[_win].wrap = false
    vim.wo[_win].spell = false
    vim.wo[_win].winfixbuf = true
    vim.wo[_win].winfixheight = true
    vim.wo[_win].winfixwidth = true

    apply_width()

    vim.api.nvim_create_autocmd("VimResized", {
        group = _augroup,
        callback = apply_width,
    })
end

local function close()
    if _win and is_valid(_win) then
        vim.api.nvim_win_close(_win, true)
    end
    _win = nil
end

function M.toggle()
    if _win and is_valid(_win) then
        close()
    else
        open()
    end
end

function M.open()
    open()
end

function M.close()
    close()
end

function M.is_visible()
    return _win and is_valid(_win)
end

return M
