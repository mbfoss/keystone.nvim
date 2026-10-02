local M = {}

local cfgmod = require("keystone.symboltree.config")


---The live options, held by `keystone.symboltree.config`; the same table, so
---`keystone.health` and the submodules all see one config.
---@type keystone.symboltree.Config
M.config = cfgmod.current

---Options that are valid but have no default, so `get_default_config()` has no
---key for them; `keystone.health` would otherwise call them misspellings.
---@type table<string, true>
M.config_optional = {
    exclude_kinds = true,
}

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

    vim.api.nvim_create_user_command("SymbolTree", function(cmd_opts)
        -- nargs="*" always yields fargs; the fallback is only to satisfy its
        -- optional type. Errors become notifications, not stack traces.
        local ok, err = pcall(require("keystone.symboltree.command").run_command,
            cmd_opts.name, cmd_opts.fargs or {}, cmd_opts)
        if not ok then
            vim.notify(
                "[keystone.util.nvim] " .. cmd_opts.name .. " command error\n" .. tostring(err),
                vim.log.levels.ERROR
            )
        end
    end, {
        nargs = "*",
        desc = "LSP symbol tree window",
        complete = function(arg_lead, cmd_line, _)
            return require("keystone.util.usercmd").complete(arg_lead, cmd_line, function(cmd, rest)
                return require("keystone.symboltree.command").get_subcommands(cmd, rest)
            end)
        end,
    })
end

return M
