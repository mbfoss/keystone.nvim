local M = {}


---@class keystone.filetree.Config
---@field width_ratio number?

---@return keystone.filetree.Config
local function _get_default_config()
    ---@type keystone.filetree.Config
    return {
         width_ratio = 0.2
    }
end

---@type keystone.filetree.Config
M.config = _get_default_config()

---@param opts table?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
    require("keystone.utils.usercmd").register_user_cmd("Filetree", "keystone.filetree.command")
end

return M
