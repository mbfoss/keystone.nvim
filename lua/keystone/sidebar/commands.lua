local M = {}

local sidebar = require("keystone.sidebar.sidebar")

function M.sidebar_command(command, name)
    if command == nil or command == "" then
        sidebar.toggle()
    elseif command == "show" then
        sidebar.show_by_name(name)
    elseif command == "hide" then
        sidebar.hide()
    else
        vim.notify("Invalid sidebar command: " .. tostring(command))
    end
end

return M