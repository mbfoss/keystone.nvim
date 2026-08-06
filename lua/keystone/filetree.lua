local M = {}


---@class keystone.filetree.Config
---@field width_ratio number?
---@field follow_current_buffer boolean?

---@return keystone.filetree.Config
local function _get_default_config()
    ---@type keystone.filetree.Config
    return {
        width_ratio = 0.2,
        follow_current_buffer = false,
    }
end

---@type keystone.filetree.Config
M.config = _get_default_config()

---@param opts table?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

    vim.api.nvim_create_user_command("FileTree", function(cmd_opts)
        require("keystone.util.usercmd").handle(cmd_opts, function(cmd, args, run_opts)
            require("keystone.filetree.command").run_command(cmd, args, run_opts)
        end)
    end, {
        nargs = "*",
        desc = "File tree window",
        complete = function(arg_lead, cmd_line, _)
            return require("keystone.util.usercmd").complete(arg_lead, cmd_line, function(cmd, rest)
                return require("keystone.filetree.command").get_subcommands(cmd, rest)
            end)
        end,
    })
end

return M
