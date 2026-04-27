local M = {}
local strutils = require('keystone.utils.strutils')

---@param commands_module string
local function _complete(commands_module, arg_lead, cmd_line)
    local mod = require(commands_module)
    local function filter(strs)
        local out = {}
        for _, s in ipairs(strs or {}) do
            if not vim.startswith(s, '_') and vim.startswith(s, arg_lead) then
                table.insert(out, s)
            end
        end
        return out
    end

    local args = strutils.split_shell_args(cmd_line)
    if cmd_line:match("%s+$") then
        table.insert(args, ' ')
    end

    local cmd = args[1]
    if #args == 1 then
        return filter(mod.get_subcommands(cmd))
    elseif #args >= 2 then
        local rest = { unpack(args, 2) }
        rest[#rest] = nil
        return filter(mod.get_subcommands(cmd, rest))
    end
    return {}
end

---@param cmd string
---@param commands_module string
---@param opts vim.api.keyset.create_user_command.command_args
local function _dispatch(cmd, commands_module, opts)
    local mod = require(commands_module)
    local args = strutils.split_shell_args(opts.args)
    local ok, err = pcall(mod.run_command, cmd, args, opts)
    if not ok then
        vim.notify(
            "[keystone.nvim] " .. cmd .. " command error\n" .. tostring(err),
            vim.log.levels.ERROR
        )
    end
end

---@param cmd string
---@param commands_module string
---@param opts {desc:string}?
function M.register_user_cmd(cmd, commands_module, opts)
    opts = opts or {}
    vim.api.nvim_create_user_command(cmd, function(cmd_opts)
            _dispatch(cmd, commands_module, cmd_opts)
        end,
        {
            nargs = "*",
            complete = function(arg_lead, cmd_line, _)
                return _complete(commands_module, arg_lead, cmd_line)
            end,
            desc = opts.desc,
        })
end

return M
