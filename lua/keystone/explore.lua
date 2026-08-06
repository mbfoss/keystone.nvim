local M = {}

---@class keystone.explore.Config
---@field unused any

local function _get_default_config()
    ---@type keystone.explore.Config
    return {
    }
end

---@type keystone.explore.Config
M.config = _get_default_config()

---@param opts keystone.explore.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
    vim.api.nvim_create_user_command("FileSelector", function(cmd_opts)
        require("keystone.util.usercmd").handle(cmd_opts, function(cmd, args, run_opts)
            require("keystone.explore.command").run_command(cmd, args, run_opts)
        end)
    end, {
        nargs = "*",
        desc = "Explore",
        complete = function(arg_lead, cmd_line, _)
            return require("keystone.util.usercmd").complete(arg_lead, cmd_line, function(cmd, rest, lead)
                return require("keystone.explore.command").get_subcommands(cmd, rest, lead)
            end)
        end,
    })
end

return M
