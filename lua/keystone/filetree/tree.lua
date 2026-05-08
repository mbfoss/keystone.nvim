local M = {}

local config = require("keystone.filetree").config

local KEY_MARKER = "Keystone_filetreewin"
local _augroup = vim.api.nvim_create_augroup("keystone_filetree", { clear = true })

local _win = nil
local _tree = nil ---@type keystone.FileTree?

---@param win number
---@return boolean
local function is_valid(win)
    if not vim.api.nvim_win_is_valid(win) then return false end
    local ok, val = pcall(function()
        return vim.w[win][KEY_MARKER]
    end)
    return ok and val == true
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

    if not _tree then
        local FileTree = require("keystone.filetree.FileTree")
        _tree = FileTree:new({
            track_current_file = {
                enabled = true,
                auto_collapse_others = true,
            },
        })
    end
    _tree:create_buffer()
    local bufnr = _tree:get_bufnr()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local filename = vim.api.nvim_buf_get_name(0)
    local last_win = vim.api.nvim_get_current_win()
    vim.cmd("topleft vsplit")
    _win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(last_win)

    vim.w[_win][KEY_MARKER] = true

    local bufname = "keystone://" .. bufnr .. "/File Tree"
    vim.api.nvim_buf_set_name(bufnr, bufname)
    vim.api.nvim_win_set_buf(_win, bufnr)

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

    _tree:reveal(filename, true, true)
end

local function close()
    if _tree then
        _tree:delete_buffer()
    end
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
