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
            return require("keystone.util.usercmd").complete_filename(arg_lead, "dir")
        end
    end
    return {}
end

--- Root for a `FileTree` call with no directory argument: the cwd on the first
--- open. Afterwards nil, leaving the tree on its existing root.
---@return string?
local function _default_dir()
    if _tree().has_tree() then return nil end
    return vim.fn.getcwd()
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
        local dir = args[1] and vim.fn.fnamemodify(args[1], ":p") or _default_dir()
        if dir and vim.fn.isdirectory(dir) == 0 then
            vim.notify("Not a directory: " .. dir, vim.log.levels.ERROR)
            return
        end
        _tree().activate(dir)
    end
end

return M
