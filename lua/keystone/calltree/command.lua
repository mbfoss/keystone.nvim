local M = {}

local function _tree()
    return require("keystone.calltree.tree")
end

---@param cmd string
---@param rest string[]
---@param for_cmd_menu boolean?
---@return string[]
function M.get_subcommands(cmd, rest, for_cmd_menu)
    if cmd == "CallTree" then
        if #rest == 0 then
            return { "open", "incoming", "outgoing", "swap", "refresh", "close", "toggle" }
        end
    end
    return {}
end

---@param cmd string
---@param args string[]
---@param opts vim.api.keyset.create_user_command.command_args
function M.run_command(cmd, args, opts)
    if cmd == "CallTree" then
        local command = args[1]
        -- No argument re-targets the symbol under the cursor rather than
        -- toggling, so repeating the command follows you around the code, and
        -- it moves focus into the window so the tree is navigable at once.
        if command == nil or command == "" then
            _tree().activate()
        elseif command == "open" then
            _tree().open()
        elseif command == "toggle" then
            _tree().toggle()
        elseif command == "incoming" then
            _tree().activate("incoming")
        elseif command == "outgoing" then
            _tree().activate("outgoing")
        elseif command == "swap" then
            _tree().swap_direction()
        elseif command == "refresh" then
            _tree().refresh()
        elseif command == "close" then
            _tree().close()
        else
            vim.notify("Invalid CallTree command: " .. tostring(command))
        end
    end
end

return M
