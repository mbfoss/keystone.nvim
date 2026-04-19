local M = {}

---@class keystone.Config
---@field use_fd_find boolean

local function _get_default_config()
    ---@type keystone.Config
    return {
        use_fd_find = false,
    }
end

---@type keystone.Config
M.config = _get_default_config()


---@param opts keystone.Config?
function M.setup(opts)
    vim.ui.select = require("keystone.pick.select").select
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
    require("keystone.utils.usercmd").register_user_cmd("Pick", "keystone.pick.command",
        { desc = "Picker for files, grep etc..." })
end

return M
