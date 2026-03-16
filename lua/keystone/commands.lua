local M = {}

-- Dependencies
local manager = require("keystone.manager")
local strtools = require('loop.tools.strtools')
local selector = require('loop.tools.selector')

function M.complete(arg_lead, cmd_line)
    local function filter(strs)
        local out = {}
        for _, s in ipairs(strs or {}) do
            if not vim.startswith(s, '_') and vim.startswith(s, arg_lead) then
                table.insert(out, s)
            end
        end
        return out
    end

    local args = strtools.split_shell_args(cmd_line)
    if cmd_line:match("%s+$") then
        table.insert(args, ' ')
    end

    if #args == 2 then
        return filter(manager.get_commands())
    elseif #args >= 3 then
        local cmd = args[2]
        local rest = { unpack(args, 3) }
        rest[#rest] = nil
        return filter(manager.get_subcommands(cmd, rest))
    end
    return {}
end

---@param prefix string[]   -- e.g. { "task" }
---@param out string[]
local function _collect_commands(prefix, out)
    local first = prefix[1]
    table.remove(prefix, 1)
    local cmds = manager.get_subcommands(first, prefix, true)

    for _, cmd in ipairs(cmds or {}) do
        local parts = vim.list_extend(vim.deepcopy(prefix), { cmd })
        table.insert(out, ("Keystone %s %s"):format(first, table.concat(parts, " ")))
        -- recurse to catch deeper subcommands
        _collect_commands(parts, out)
    end
end

function M.select_command()
    ---@type string[]
    local all_cmds = {}

    -- Top-level commands
    for _, cmd in ipairs(manager.get_commands()) do
        table.insert(all_cmds, "Keystone " .. cmd)
        -- Subcommands (recursive)
        _collect_commands({ cmd }, all_cmds)
    end

    local choices = {}
    for _, cmd in ipairs(all_cmds) do
        ---@type loop.SelectorItem
        local item = {
            label = cmd,
            data = cmd,
        }
        table.insert(choices, item)
    end
    selector.select({
            prompt = "Select command",
            items = choices,
        },
        function(cmd)
            if cmd then
                vim.cmd(cmd)
            end
        end
    )
end

-----------------------------------------------------------
-- Dispatcher
-----------------------------------------------------------

---@param opts vim.api.keyset.create_user_command.command_args
function M.dispatch(opts)
    local args = strtools.split_shell_args(opts.args)
    local subcmd = args[1]

    if not subcmd or subcmd == "" then
        M.select_command()
        return
    end
    local rest = { unpack(args, 2) }
    local ok, err = pcall(manager.run_command, subcmd, rest, opts)
    if not ok then
        vim.notify(
            "Keystone " .. subcmd .. " failed: " .. tostring(err),
            vim.log.levels.ERROR
        )
    end
end

return M
