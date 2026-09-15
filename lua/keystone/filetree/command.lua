local M = {}

local function _tree()
    return require("keystone.filetree.tree")
end

---@param cmd string
---@param rest string[]
---@param arg_lead string
---@return string[]
function M.get_subcommands(cmd, rest, arg_lead)
    if cmd == "FileTree" then
        if #rest == 0 then
            return { "open", "close", "toggle" }
        elseif #rest == 1 and rest[1] == "open" then
            return vim.fn.getcompletion(arg_lead, "dir")
        end
    end
    return {}
end

---@param cmd string
---@param args string[]
---@param opts vim.api.keyset.create_user_command.command_args
function M.run_command(cmd, args, opts)
    if cmd == "FileTree" then
        local command = args[1]
        local name = args[2]
        if command == nil or command == "" or command == "open" then
            local dir = name and vim.fn.fnamemodify(name, ":p")
            if dir and vim.fn.isdirectory(dir) == 0 then
                vim.notify("Not a directory: " .. dir, vim.log.levels.ERROR)
                return
            end
            _tree().open(dir)
        elseif command == "close" then
            _tree().close()
        elseif command == "toggle" then
            _tree().toggle()
        else
            vim.notify("Invalid Filetree command: " .. tostring(command))
        end
    end
end

return M
