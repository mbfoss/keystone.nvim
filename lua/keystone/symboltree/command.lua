local M = {}

local function _tree()
    return require("keystone.symboltree.tree")
end

---@param cmd string
---@param rest string[]
---@param for_cmd_menu boolean?
---@return string[]
function M.get_subcommands(cmd, rest, for_cmd_menu)
    if cmd == "SymbolTree" then
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
    if cmd == "SymbolTree" then
        local command = args[1]
        if command == nil or command == "" or command == "toggle" then
            _tree().toggle()
        elseif command == "open" then
            _tree().open()
        elseif command == "close" then
            _tree().close()
        else
            vim.notify("Invalid SymbolTree command: " .. tostring(command))
        end
    end
end

return M
