local M = {}

---@class keystone.explore.Config
---@field detail_fields keystone.explore.DetailField[] Per-entry details shown right-aligned, in order. Empty disables them.
---@field min_list_width number|false? Cells the list keeps however narrow the width ratio works out. False leaves it to the ratio alone.

local function _get_default_config()
    ---@type keystone.explore.Config
    return {
        detail_fields = { "size", "mtime" },
        min_list_width = 80,
    }
end

---@type keystone.explore.Config
M.config = _get_default_config()

---@param opts keystone.explore.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
    -- Replaced wholesale: deep-extend merges lists by index, which would keep
    -- defaults past the end of a shorter user-supplied list.
    if opts and opts.detail_fields then
        M.config.detail_fields = opts.detail_fields
    end
    require("keystone.explore.command").configure({
        detail_fields = M.config.detail_fields,
        min_list_width = M.config.min_list_width,
    })
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
