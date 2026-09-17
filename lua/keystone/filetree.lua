local M = {}


---@class keystone.filetree.Config
---@field width_ratio number?   fraction of the editor width the window takes (left/right)
---@field height_ratio number?  fraction of the editor height the window takes (top/bottom)
---@field position "top"|"bottom"|"left"|"right"?  side the window opens on
---@field follow_current_buffer boolean?

---@type keystone.filetree.Config
local _default_config = {
    width_ratio = 0.2,
    height_ratio = 0.3,
    position = "left",
    follow_current_buffer = false,
}

---@type keystone.filetree.Config
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
