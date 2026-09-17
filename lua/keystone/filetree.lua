local M = {}

local cfgmod = require("keystone.filetree.config")


---The live options, held by `keystone.filetree.config`; the same table, so
---`keystone.health` and the submodules all see one config.
---@type keystone.filetree.Config
M.config = cfgmod.current

local _setup = false

--- A fresh copy of the module defaults, as `setup()` starts from. Safe to mutate.
---@return table
function M.get_default_config()
    return cfgmod.defaults()
end

--- Whether `setup()` has been called for this module.
---@return boolean
function M.is_setup()
    return _setup
end

---@param opts table?
function M.setup(opts)
    _setup = true
    cfgmod.apply(opts)

    vim.api.nvim_create_user_command("FileTree", function(cmd_opts)
        require("keystone.util.usercmd").handle(cmd_opts, function(cmd, args, run_opts)
            require("keystone.filetree.command").run_command(cmd, args, run_opts)
        end)
    end, {
        nargs = "*",
        desc = "File tree window",
        complete = function(arg_lead, cmd_line, _)
            return require("keystone.util.usercmd").complete(arg_lead, cmd_line, function(cmd, rest, lead)
                return require("keystone.filetree.command").get_subcommands(cmd, rest, lead)
            end)
        end,
    })
end

return M
