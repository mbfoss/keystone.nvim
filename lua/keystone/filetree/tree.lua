local M = {}

local config = require("keystone.filetree").config

local KEY_MARKER = "Keystone_filetreewin"

local _tree ---@type keystone.FileTree?

---@return number?
local function get_win()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
        local ok, val = pcall(function() return vim.w[win][KEY_MARKER] end)
        if ok and val == true then return win end
    end
    return nil
end

---@param win number
local function apply_width(win)
    local total = vim.o.columns
    local width = math.floor(total * (config.width_ratio or 0.2))
    vim.api.nvim_win_set_width(win, width)
end

local function open()
    local win = get_win()
    if win then return end

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
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(last_win)

    vim.w[win][KEY_MARKER] = true

    local bufname = "keystone://" .. bufnr .. "/File Tree"
    vim.api.nvim_buf_set_name(bufnr, bufname)
    vim.api.nvim_win_set_buf(win, bufnr)

    vim.wo[win].wrap = false
    vim.wo[win].spell = false
    vim.wo[win].winfixbuf = true
    vim.wo[win].winfixheight = true
    vim.wo[win].winfixwidth = true

    apply_width(win)

    local augroup_name = "keystone_filetree_w" .. win
    local augroup = vim.api.nvim_create_augroup(augroup_name, { clear = true })
    vim.api.nvim_create_autocmd("VimResized", {
        group = augroup,
        callback = apply_width,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = augroup,
        callback = function(args)
            local closedwin = tonumber(args.match)
            if closedwin ~= win then
                apply_width(win)
            else
                win = nil
                vim.schedule(function()
                    if _tree then
                        _tree:delete_buffer()
                    end
                end)
                vim.api.nvim_del_augroup_by_id(augroup)
            end
        end,
    })

    _tree:reveal(filename, true, true)
end

function M.toggle()
    local win = get_win()
    if win then
        vim.api.nvim_win_close(win, false)
    else
        open()
    end
end

function M.open()
    open()
end

function M.close()
    local win = get_win()
    if win then
        vim.api.nvim_win_close(win, false)
    end
end

function M.is_visible()
    return get_win() ~= nil
end

return M
