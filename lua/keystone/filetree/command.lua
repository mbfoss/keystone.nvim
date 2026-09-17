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
        if #args > 1 then
            vim.notify("FileTree takes at most one directory", vim.log.levels.ERROR)
            return
        end
        local dir = args[1] and vim.fn.fnamemodify(args[1], ":p")
        if dir and vim.fn.isdirectory(dir) == 0 then
            vim.notify("Not a directory: " .. dir, vim.log.levels.ERROR)
            return
        end
        _tree().open(dir)
    end
end

return M
