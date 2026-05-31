local M = {}

local _subcommand_list = { "set", "delete", "list", "clear_file", "clear_all" }

---@param _ string
---@param rest string[]
---@return string[]
function M.get_subcommands(_, rest)
    if #rest == 0 then return _subcommand_list end
    return {}
end

---@param _ string
---@param args string[]
---@param _opts vim.api.keyset.create_user_command.command_args
function M.run_command(_, args, _opts)
    local bookmarks = require("keystone.bookmarks")
    local cmd = args[1] or "set"
    if cmd == "set" then
        bookmarks.set_at_cursor()
    elseif cmd == "delete" then
        bookmarks.delete_at_cursor()
    elseif cmd == "list" then
        bookmarks.pick()
    elseif cmd == "clear_file" then
        bookmarks.clear_file()
    elseif cmd == "clear_all" then
        bookmarks.clear_all()
    else
        vim.notify("[keystone] Unknown Bookmarks subcommand: " .. tostring(cmd), vim.log.levels.WARN)
    end
end

return M
