local M = {}

---@class keystone.explore.Config
---@field override_ui_select boolean?
---@field use_fd_find boolean

local function _get_default_config()
    ---@type keystone.explore.Config
    return {
        override_ui_select = true,
        use_fd_find = false,
    }
end

---@type keystone.explore.Config
M.config = _get_default_config()


---@param opts keystone.explore.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
    require("keystone.utils.usercmd").register_user_cmd("FileSelector", function(cmd, args, opts)
            require("keystone.explore.command").run_command(cmd, args, opts)
        end,
        {
            desc = "Explore",
            subcommand_fn = function(cmd, rest)
                return require("keystone.explore.command").get_subcommands(cmd, rest)
            end
        })
end

return M
