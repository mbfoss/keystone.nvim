local M = {}

local function sidebar()
    return require("keystone.sidebar.sidebar")
end

---@param cmd string
---@param rest string[]
---@param for_cmd_menu boolean?
---@return string[]
function M.get_subcommands(cmd, rest, for_cmd_menu)
    if cmd == "Sidebar" then
        if #rest == 0 then
            return { "show", "hide", "toggle" }
        end
    end
    return {}
end

---@param cmd string
---@param args string[]
---@param opts vim.api.keyset.create_user_command.command_args
function M.run_command(cmd, args, opts)
    if cmd == "Sidebar" then
        local command = args[1]
        local name = args[2]
        if command == nil or command == "" or command == "toggle" then
            sidebar().toggle()
        elseif command == "show" then
            sidebar().show_by_name(name)
        elseif command == "hide" then
            sidebar().hide()
        else
            vim.notify("Invalid sidebar command: " .. tostring(command))
        end
    end
end

return M
