local M = {}

local function _get_default_config()
    return {
    }
end

---@type keystone.Config
M.config = _get_default_config()

---@param opts keystone.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
    require("keystone.utils.usercmd").register_user_cmd("Sidebar", "keystone.sidebar.command")
end

return M
