local M = {}

-- ---------------------------------------------------------------------------
-- keystone.calltree
--
-- A side window showing the LSP call hierarchy of the symbol under the cursor:
-- who calls it (incoming, the default) or what it calls (outgoing). Children are
-- fetched lazily, one request per node the first time it is expanded, so a wide
-- hierarchy costs nothing until you look at it.
-- ---------------------------------------------------------------------------

---@class keystone.calltree.Config
---@field width_ratio number?   fraction of the editor width the window takes (left/right)
---@field height_ratio number?  fraction of the editor height the window takes (top/bottom)
---@field position "top"|"bottom"|"left"|"right"?  side the window opens on
---@field direction keystone.calltree.Direction?  which way to walk by default
---@field show_detail boolean?  show the server-provided detail text
---@field auto_expand_root boolean?  expand the root as soon as it resolves

---@type keystone.calltree.Config
local _default_config = {
    width_ratio      = 0.2,
    height_ratio     = 0.3,
    position         = "bottom",
    direction        = "incoming",
    show_detail      = true,
    auto_expand_root = true,
}

---@type keystone.calltree.Config
M.config = vim.deepcopy(_default_config)

local _setup = false

--- A fresh copy of the module defaults, as `setup()` starts from. Safe to mutate.
---@return table
function M.get_default_config()
    return vim.deepcopy(_default_config)
end

--- Whether `setup()` has been called for this module.
---@return boolean
function M.is_setup()
    return _setup
end

---@param opts table?
function M.setup(opts)
    _setup = true
    M.config = vim.tbl_deep_extend("force", vim.deepcopy(_default_config), opts or {})

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
