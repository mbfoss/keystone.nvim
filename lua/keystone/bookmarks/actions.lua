---@class keystone.bookmarks.actions
local M            = {}

-- Interactive bookmark commands. This module pulls in the heavy UI modules
-- (inputwin, ui, picker, fixedwin) and is only required the first time the user
-- triggers a command, keeping startup cheap. The entry point
-- (`keystone.bookmarks`) forwards to these on demand.

local core         = require("keystone.bookmarks.core")
local inputwin     = require("keystone.tk.inputwin")
local ui           = require("keystone.tk.ui")
local picker       = require("keystone.pick.base.picker")
local pickertools  = require("keystone.pick.base.pickertools")
local fixedwin     = require("keystone.tk.fixedwin")

-- Height ratio of the bookmarks list split, tracked live by fixedwin and reused
-- so reopening the list keeps the height the user last dragged it to.
local _list_ratio  = 0.25

function M.set_label_at_cursor()
    local file, lnum = core.get_cur_loc()
    if not file or not lnum then
        vim.notify("[keystone] No valid file at cursor", vim.log.levels.WARN)
        return
    end
    file = core.norm(file)
    local existing = core.mark_group.get_extmark_by_location(file, lnum, true)
    local default = (existing and existing.user_data and existing.user_data.label) or ""
    inputwin.open({ prompt = "Bookmark label", default = default }, function(label)
        if not label then return end
        label = label:match("^%s*(.-)%s*$")
        core.upsert(file, lnum, label ~= "" and label or nil)
    end)
end

function M.clear_file()
    local buf = vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local file = core.norm(vim.api.nvim_buf_get_name(buf))
    if not file or file == "" then return end
    ui.confirm_action("Clear bookmarks in current file", false, function(accepted)
        if not accepted then return end
        core.mark_group.remove_file_extmarks(file)
        core.refresh_list()
    end)
end

function M.clear_all()
    if #core.mark_group.get_extmarks(false) == 0 then
        return
    end
    ui.confirm_action("Clear all bookmarks", false, function(accepted)
        if not accepted then return end
        core.mark_group.remove_extmarks()
        core.refresh_list()
    end)
end

function M.pick()
    local entries = core.sorted_entries()
    if #entries == 0 then
        vim.notify("[keystone] No bookmarks set", vim.log.levels.WARN)
        return
    end

    local cur_file, cur_lnum = core.get_cur_loc()
    if cur_file then cur_file = core.norm(cur_file) end

    picker.open({
        prompt          = "Bookmarks",
        enable_preview  = true,
        enable_list_sep = true,
        finder          = function(query, _, _fetch_opts, callback)
            local items = {}
            for _, entry in ipairs(entries) do
                local relpath = vim.fn.fnamemodify(entry.file, ":~:.")
                local loc_text = relpath .. ":" .. entry.lnum
                local match = pickertools.match_label(loc_text, query)
                if match then
                    ---@type keystone.Picker.Item
                    local item = {
                        label_chunks = match.chunks,
                        virt_lines   = entry.label and { { { entry.label, "@text.note" } } } or nil,
                        score        = match.score,
                        data         = {
                            filepath = entry.file,
                            lnum     = entry.lnum,
                            col      = 0,
                        },
                    }
                    if cur_file and entry.file == cur_file and entry.lnum == cur_lnum then
                        item.initial = true
                    end
                    table.insert(items, item)
                end
            end
            callback(items)
        end,
    }, function(data)
        if data and data.filepath then
            ui.smart_open_file(data.filepath, data.lnum, data.col)
        end
    end)
end

--- Opens the bookmarks list for editing in a split. The list is a scratch buffer
--- rendered from the extmarks -- not the file on disk. Edit lines freely, then `:w`
--- to synchronise the signs; the write updates the extmark group in memory (see
--- core.sync_from_buffer) and does not touch disk -- the file is saved on exit.
--- Each line is `<path>:<lnum>[ -- <label>]`.
function M.open_list()
    -- Reuse the scratch buffer across opens so its content (kept in step with the
    -- extmarks by core.refresh_list) survives being hidden.
    local bufnr = core.list_bufnr
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
        bufnr = vim.api.nvim_create_buf(true, false)
        core.list_bufnr = bufnr

        vim.bo[bufnr].buftype = "acwrite"
        vim.bo[bufnr].bufhidden = "hide"
        vim.bo[bufnr].swapfile = false

        -- `:w` pushes the edited lines back into the extmarks (no disk write), then
        -- re-renders the canonical (sorted/normalised) form from the extmarks.
        vim.api.nvim_create_autocmd("BufWriteCmd", {
            buffer   = bufnr,
            callback = function()
                core.sync_from_buffer(bufnr)
                core.refresh_list()
            end,
        })

        -- <CR> jumps to the bookmark on the current line via the shared file opener.
        vim.keymap.set("n", "<CR>", function()
            local line = vim.api.nvim_get_current_line()
            local entry = core.decode_line(line)
            if not entry then return end
            ui.smart_open_file(entry.file, entry.lnum, 0)
        end, { buffer = bufnr, desc = "Open bookmark under cursor" })
    end

    -- Render current bookmarks into the buffer before showing it.
    core.refresh_list()

    -- Already visible: just focus it.
    local existing_win = vim.fn.bufwinid(bufnr)
    if existing_win >= 0 then
        vim.api.nvim_set_current_win(existing_win)
        return
    end

    -- A height-pinned split whose ratio fixedwin tracks across resizes/layout
    -- changes; persist the last-known ratio so reopening keeps the chosen height.
    local win = fixedwin.create_fixed_win("height", _list_ratio, function(ratio)
        _list_ratio = ratio
    end, { enter = true })
    vim.api.nvim_win_set_buf(win, bufnr)
    vim.wo[win].winfixbuf = true
end

return M
