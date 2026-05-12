---@class keystone.notifications.history.Item
---@field id string|integer
---@field title string
---@field level "info"|"warn"|"error"|"lsp"
---@field message string[]
---@field timestamp integer

local M = {}

local notifications = require("keystone.notify")
local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")

local level_hl = {
    info = "DiagnosticInfo",
    warn = "DiagnosticWarn",
    error = "DiagnosticError",
    lsp = "Normal",
}

function M.open()
    ---@type keystone.notifications.history.Item[]
    local history = notifications.history()

    table.sort(history, function(a, b)
        return a.timestamp > b.timestamp
    end)

    picker.open({
        prompt = "Notification History",

        fetch = function(query, fetch_opts)
            local items = {}
            for _, entry in ipairs(history) do
                local message = table.concat(entry.message, " ")
                local res = pickertools.match_label(message, query)
                if res then
                    local timestamp = os.date("%H:%M:%S", math.floor(entry.timestamp / 1000))
                    local chunks = {
                        {
                            string.format("[%s] ", timestamp),
                            "Comment",
                        },
                        {
                            string.format("[%-5s] ", entry.level:upper()),
                            level_hl[entry.level] or "Normal",
                        },
                        {
                            string.format("%s: ", entry.title),
                            "Title",
                        },
                    }
                    vim.list_extend(chunks, res.chunks)
                    table.insert(items, {
                        label_chunks = chunks,
                        data = {
                            message = table.concat(entry.message, "\n"),
                        },
                    })
                end
            end
            return items
        end,
    }, function(data)
        if not data then
            return
        end

        vim.fn.setreg("+", data.message)
        vim.fn.setreg('"', data.message)
    end)
end

return M
