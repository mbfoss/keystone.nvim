local M = {}

local function tree()
    return require("keystone.filetree.tree")
end

---@param cmd string
---@param rest string[]
---@param for_cmd_menu boolean?
---@return string[]
function M.get_subcommands(cmd, rest, for_cmd_menu)
    if cmd == "Filetree" then
        if #rest == 0 then
            return { "open", "close", "toggle" }
        end
    end
    return {}
end

---@param cmd string
---@param args string[]
---@param opts vim.api.keyset.create_user_command.command_args
function M.run_command(cmd, args, opts)
    if cmd == "Filetree" then
        local command = args[1]
        local name = args[2]
        if command == nil or command == "" or command == "toggle" then
            tree().toggle()
        elseif command == "open" then
            tree().open()
        elseif command == "close" then
            tree().close()
        else
            vim.notify("Invalid Filetree command: " .. tostring(command))
        end
    end
end

return M
