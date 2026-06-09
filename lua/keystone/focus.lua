local uitool = require("keystone.util.uitool")

local M = {}

---@class keystone.floatpreview.Config
---@field enabled boolean

local function _get_default_config()
    ---@type keystone.floatpreview.Config
    return {
        enabled = true,
    }
end

---@type keystone.floatpreview.Config
M.config = _get_default_config()

local _win_id = nil

function M.toggle()
    if _win_id and vim.api.nvim_win_is_valid(_win_id) then
        vim.api.nvim_win_close(_win_id, true)
        _win_id = nil
        return
    end

    local origwin = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_get_current_buf()
    local screen_width = vim.o.columns
    local screen_height = vim.o.lines

    local width = screen_width - 2
    local height = screen_height - 3 - vim.o.cmdheight -- 2 for borders, 1 for statusline

    if width < 1 or height < 1 then return end

    ---@type vim.api.keyset.win_config
    local opts = {
        relative = "editor",
        row = 1,
        col = 1,
        width = width,
        height = height,
        border = "rounded",
        footer = "Focus mode",
    }

    _win_id = uitool.create_window(bufnr, true, opts, function()
        _win_id = nil
    end)

    vim.wo[_win_id].winhighlight = "NormalFloat:Normal,FloatBorder:Nontext,FloatTitle:Nontext"
    vim.wo[_win_id].statusline = vim.wo[origwin].statusline
end

---@param opts keystone.floatpreview.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

    if M.config.enabled then
        vim.api.nvim_create_user_command("Focus", M.toggle, {})
    end
end

return M
