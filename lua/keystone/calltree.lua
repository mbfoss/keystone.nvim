local M = {}

local cfgmod = require("keystone.calltree.config")

-- ---------------------------------------------------------------------------
-- keystone.calltree
--
-- A side window showing the LSP call hierarchy of the symbol under the cursor:
-- who calls it (incoming, the default) or what it calls (outgoing). Children are
-- fetched lazily, one request per node the first time it is expanded, so a wide
-- hierarchy costs nothing until you look at it.
-- ---------------------------------------------------------------------------

---The live options, held by `keystone.calltree.config`; the same table, so
---`keystone.health` and the submodules all see one config.
---@type keystone.calltree.Config
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

    vim.api.nvim_create_user_command("CallTree", function(cmd_opts)
        require("keystone.util.usercmd").handle(cmd_opts, function(cmd, args, run_opts)
            require("keystone.calltree.command").run_command(cmd, args, run_opts)
        end)
    end, {
        nargs = "*",
        desc = "LSP call hierarchy window",
        complete = function(arg_lead, cmd_line, _)
            return require("keystone.util.usercmd").complete(arg_lead, cmd_line, function(cmd, rest)
                return require("keystone.calltree.command").get_subcommands(cmd, rest)
            end)
        end,
    })
end

return M
