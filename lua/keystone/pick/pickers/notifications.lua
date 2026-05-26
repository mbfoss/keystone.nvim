---@class keystone.notifications.history.Item
---@field id string|integer
---@field title string
---@field level "info"|"warn"|"error"|"lsp"
---@field message string[]
---@field timestamp integer

local M             = {}

local notifications = require("keystone.notify")
local picker        = require("keystone.pick.base.picker")
local pickertools   = require("keystone.pick.base.pickertools")
local strutils      = require("keystone.utils.strutils")
local uitools       = require("keystone.utils.uitools")

local _icons        = {
    info = "󰋽",
    warn = "󰀪",
    error = "󰅚",
    lsp = "󰒓",
}

local _level_hl     = {
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
        finder = function(query, _, fetch_opts, callback)
            local items = {}
            for _, entry in ipairs(history) do
                local text = strutils.crop_string_for_ui(table.concat(entry.message, " "), fetch_opts.list_width)
                local res = pickertools.match_label(text, query)
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
                            message = entry.message,
                        },
                    })
                end
            end
            callback(items)
        end,
        previewer = function(data, opts, callback)
            callback({
                content = data.message,
            })
            return function() end
        end
    }, function(data)
        if not data then
            return
        end

        local bufnr = uitools.create_sratch_buffer(true, {})
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, data.message)
        vim.api.nvim_set_current_buf(bufnr)
    end)
end

return M
