local M = {}

-- Browsing the notification history is a picker job, so it goes through
-- `vim.ui.select` -- keystone's own `keystone.select` when that module is
-- enabled, whichever implementation the user installed otherwise. The preview
-- rides on the `preview_item` extension; implementations that do not know it
-- simply ignore it, and the picker still lists and confirms.
--
-- Required only when `:Notifications` first runs, so `keystone.notify.setup`
-- stays a single lightweight require.

local notify   = require("keystone.notify")
local strutil  = require("keystone.util.strutil")
local ui       = require("keystone.util.ui")

local _icons   = {
    info  = "󰋽",
    warn  = "󰀪",
    error = "󰅚",
    lsp   = "󰒓",
}

--- Longest single-line form of an entry, cropped to what a label can show.
---@param entry keystone.notify.HistoryEntry
---@return string
local function _label(entry)
    local timestamp = os.date("%H:%M:%S", math.floor(entry.timestamp / 1000))
    local text      = table.concat(entry.message, " ")
    return string.format("[%s] %s %s", timestamp, _icons[entry.level] or "", text)
end

--- List the notification history, newest first.
---@return nil
function M.open()
    local history = notify.history()
    if #history == 0 then
        vim.notify("No notifications", vim.log.levels.INFO, { title = "Notifications" })
        return
    end

    ---@type keystone.notify.HistoryEntry[]
    local entries = {}
    for i = #history, 1, -1 do
        entries[#entries + 1] = history[i]
    end

    -- One buffer for every preview: the picker only ever displays one at a
    -- time, and it is wiped once the picker is done with it. 'hide', not the
    -- scratch default 'wipe' -- the picker takes it out of its window on every
    -- move, which would wipe it away mid-picker.
    local preview_buf = ui.create_scratch_buffer(false, { modifiable = false, bufhidden = "hide" })

    vim.ui.select(entries, {
        prompt = "Notifications",
        ---@param entry keystone.notify.HistoryEntry
        format_item = function(entry)
            return (strutil.crop_for_ui(_label(entry), math.max(20, math.floor(vim.o.columns * 0.6))))
        end,
        ---@param entry keystone.notify.HistoryEntry
        ---@return keystone.select.Preview?
        preview_item = function(entry)
            if not vim.api.nvim_buf_is_valid(preview_buf) then return nil end
            vim.bo[preview_buf].modifiable = true
            vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, entry.message)
            vim.bo[preview_buf].modifiable = false
            return { buf = preview_buf }
        end,
    }, function(entry)
        if vim.api.nvim_buf_is_valid(preview_buf) then
            vim.api.nvim_buf_delete(preview_buf, { force = true })
        end
        if not entry then return end

        local bufnr = ui.create_scratch_buffer(true, {})
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, entry.message)
        ui.smart_open_buffer(bufnr)
    end)
end

return M
