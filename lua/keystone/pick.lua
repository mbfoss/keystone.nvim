local M = {}

---@class keystone.pick.Config
---@field override_ui_select boolean?
---@field use_fd_find boolean

local function _get_default_config()
    ---@type keystone.pick.Config
    return {
        override_ui_select = true,
        use_fd_find = false,
    }
end

---@type keystone.pick.Config
local config = _get_default_config()


---@param opts keystone.pick.Config?
function M.setup(opts)
    config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
    require("keystone.utils.usercmd").register_user_cmd("Pick", "keystone.pick.command",
        { desc = "Picker for files, grep etc..." })
    if config.override_ui_select then
        vim.ui.select = require("keystone.pick.select").select
    end
end

return M
