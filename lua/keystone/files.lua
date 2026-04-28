local M = {}


---@class keystone.files.Config
---@field unused number?

---@return keystone.files.Config
local function _get_default_config()
    ---@type keystone.files.Config
    return {
    }
end

---@type keystone.files.Config
M.config = _get_default_config()

---@param opts table?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

    require("keystone.utils.usercmd").register_user_cmd("Files", function(cmd, args, opts)
            local selector = require("keystone.files.selector")
            selector.open({}, function (data)
                
            end)
        end,
        {
            desc = "Files selector",
        })
end

return M
