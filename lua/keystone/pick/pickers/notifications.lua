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

local _icons = {
    info = "ℹ",
    warn = "⚠",
    error = "✖",
    lsp = "⚙",
}

local _level_hl = {
    info = "DiagnosticInfo",
    warn = "DiagnosticWarn",
    error = "DiagnosticError",
    lsp = "Normal",
}

function M.open()
    ---@type keystone.notifications.history.Item[]
    local history = notifications.history()
    local reversed = {}
    for i = #history, 1, -1 do reversed[#reversed + 1] = history[i] end
    history = reversed

    picker.open({
        prompt = "Notification History",
        enable_preview = true,
        fetch = function(query, fetch_opts)
            local items = {}
            for _, entry in ipairs(history) do
                local message = table.concat(entry.message, " ")
                local res = pickertools.match_label(message, query)
                if res then
                    local timestamp = os.date("%H:%M:%S", math.floor(entry.timestamp / 1000))
                    local chunks = {
                        { string.format("[%s] ", timestamp), "Comment", },
                        { _icons[entry.level] or "",         _level_hl[entry.level] or "Normal", },
                        { " ",                               _level_hl[entry.level] or "Normal", },
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
        async_preview = function(data, opts, callback)
            callback({
                content = data.message,
            })
            return function() end
        end
    }, function(data)
        if not data then
            return
        end

        vim.fn.setreg("+", data.message)
        vim.fn.setreg('"', data.message)
    end)
end

return M
