local M = {}

local cfgutil = require("keystone.util.config")

---@class keystone.explore.Config
---@field detail_fields keystone.explore.DetailField[] Per-entry details shown right-aligned, in order. Empty disables them.

---@type keystone.explore.Config
local _default_config = {
    detail_fields = { "size", "mtime" },
}

---@type keystone.explore.Config
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

---@param opts keystone.explore.Config?
function M.setup(opts)
    _setup = true
    cfgutil.apply(M.config, _default_config, opts)
    -- Replaced wholesale: deep-extend merges lists by index, which would keep
    -- defaults past the end of a shorter user-supplied list.
    if opts and opts.detail_fields then
        M.config.detail_fields = opts.detail_fields
    end
    require("keystone.explore.command").configure({ detail_fields = M.config.detail_fields })
    vim.api.nvim_create_user_command("FileSelector", function(cmd_opts)
        -- nargs="*" always yields fargs; the fallback is only to satisfy its
        -- optional type. Errors become notifications, not stack traces.
        local ok, err = pcall(require("keystone.explore.command").run_command,
            cmd_opts.name, cmd_opts.fargs or {}, cmd_opts)
        if not ok then
            vim.notify(
                "[keystone.util.nvim] " .. cmd_opts.name .. " command error\n" .. tostring(err),
                vim.log.levels.ERROR
            )
        end
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
