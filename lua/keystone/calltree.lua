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
---@field width_ratio number?   fraction of the editor width the window takes
---@field position "left"|"right"?  side the window opens on
---@field direction keystone.calltree.Direction?  which way to walk by default
---@field show_detail boolean?  show the server-provided detail text
---@field auto_expand_root boolean?  expand the root as soon as it resolves

---@return keystone.calltree.Config
local function _get_default_config()
    ---@type keystone.calltree.Config
    return {
        width_ratio      = 0.25,
        position         = "left",
        direction        = "incoming",
        show_detail      = true,
        auto_expand_root = true,
    }
end

---@type keystone.calltree.Config
M.config = _get_default_config()

---@param opts table?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

    require("keystone.tk.usercmd").register_user_cmd("CallTree", function(cmd, args, opts)
            require("keystone.calltree.command").run_command(cmd, args, opts)
        end,
        {
            desc = "LSP call hierarchy window",
            subcommand = function(cmd, rest)
                return require("keystone.calltree.command").get_subcommands(cmd, rest)
            end
        })
end

return M
