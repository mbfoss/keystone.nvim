---@class keystone.bookmarks.actions
local M           = {}

-- Interactive bookmark commands. This module pulls in the heavy UI modules
-- (inputwin, ui, picker, fixedwin) and is only required the first time the user
-- triggers a command, keeping startup cheap. The entry point
-- (`keystone.bookmarks`) forwards to these on demand.

local core        = require("keystone.bookmarks.core")
local throttle    = require("keystone.tk.throttle")
local inputwin    = require("keystone.tk.inputwin")
local ui          = require("keystone.tk.ui")
local picker      = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local fixedwin    = require("keystone.tk.fixedwin")

-- Height ratio of the bookmarks list split, tracked live by fixedwin and reused
-- so reopening the list keeps the height the user last dragged it to.
local _list_ratio = 0.25

--- `completefunc` for the bookmarks list buffer (triggered with <C-x><C-u>):
--- completes the file path in the first field of the current line. Scoped to the
--- leading path token -- bytes up to the cursor that are neither whitespace nor
--- the `:` that introduces the line number -- and only when nothing but
--- whitespace precedes it, so the `:lnum` and ` -- label` after the path are never
--- treated as a path. `getcompletion(_, "file")` keeps the stored path form
--- (cwd- or `~`-relative) and marks directories with a trailing `/`.
---@param findstart 0|1
---@param base string
---@return integer|string[]
function M.complete_path(findstart, base)
    local line   = vim.api.nvim_get_current_line()
    local col    = vim.api.nvim_win_get_cursor(0)[2] -- 0-based cursor byte offset
    local before = line:sub(1, col)
    local token  = before:match("[^%s:]*$")
    local start  = col - #token

    if findstart == 1 then
        -- Not in the first field (or nothing to complete): cancel, stay in insert.
        if token == "" or before:sub(1, start):match("%S") then return -2 end
        return start -- 0-based byte column where the path token begins
    end

    return vim.fn.getcompletion(base, "file")
end

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
                local label = entry.label
                -- Match against the location *and* the label, so a bookmark can be
                -- found by words in its note. The location keeps its own highlight
                -- chunks on the main line; the label gets its own on the virt line
                -- below, with the note group as the base for unmatched text.
                local search_text = label and (loc_text .. " " .. label) or loc_text
                local match = pickertools.match_label(search_text, query)
                if match then
                    local loc_match = pickertools.match_label(loc_text, query)
                    local virt_lines
                    if label then
                        local label_match = pickertools.match_label(label, query)
                        local chunks = (label_match and label_match.chunks) or { { label } }
                        -- match_label leaves unmatched chunks without a highlight; give
                        -- them the note group so the label keeps its styling, while the
                        -- matched chunks keep their match highlight.
                        for _, chunk in ipairs(chunks) do
                            if not chunk[2] then chunk[2] = "@text.note" end
                        end
                        virt_lines = { chunks }
                    end
                    ---@type keystone.Picker.Item
                    local item = {
                        label_chunks = (loc_match and loc_match.chunks) or { { loc_text } },
                        virt_lines   = virt_lines,
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
--- rendered from the extmarks -- not the file on disk. Edit lines freely; edits
--- synchronise the signs automatically (throttled), updating the extmark group in
--- memory (see core.sync_from_buffer) without touching disk -- the file is saved on
--- exit. `:w` is unnecessary (and a no-op). Each line is `<path>:<lnum>[ -- <label>]`;
--- <C-x><C-u> completes the file path in the first field.
function M.open_list()
    -- Reuse the scratch buffer across opens so its content (kept in step with the
    -- extmarks by core.refresh_list) survives being hidden.
    local bufnr = core.list_bufnr
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
        bufnr = ui.create_scratch_buffer(true, {}, function()
            bufnr = nil
            core.list_bufnr = nil
        end)
        core.list_bufnr = bufnr

        -- `acwrite`, not `nofile`: it keeps the no-disk-backing scratch semantics
        -- while still giving the buffer a name, so `:w` is a clean no-op instead
        -- of aborting with E32. Syncing no longer depends on `:w` -- edits flow
        -- into the extmarks automatically (see the throttled TextChanged sync).
        local name = "keystone://bookmarks"
        local existing = vim.fn.bufnr(name)
        if existing ~= -1 and existing ~= bufnr then
            vim.api.nvim_buf_delete(existing, { force = false })
        end
        vim.api.nvim_buf_set_name(bufnr, name)
        vim.bo[bufnr].buftype = "acwrite"
        vim.bo[bufnr].bufhidden = "hide"
        vim.bo[bufnr].swapfile = false

        -- Complete file paths in the first field via <C-x><C-u>. LSP completion
        -- lives on 'omnifunc' (keystone.lspcompletion), so our own completefunc
        -- here does not collide with it. See M.complete_path.
        vim.bo[bufnr].completefunc = "v:lua.require'keystone.bookmarks.actions'.complete_path"

        -- Push edited lines back into the extmarks as the user edits, throttled so a
        -- burst of keystrokes rebuilds the group at most once per window. Only syncs
        -- (no refresh_list): re-rendering the canonical/sorted form mid-edit would
        -- fight the cursor -- that normalisation happens on the next open_list.
        local auto_sync = throttle.throttle_wrap(150, function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                core.sync_from_buffer(bufnr)
            end
        end)
        vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
            buffer   = bufnr,
            callback = auto_sync,
        })

        -- The buffer is kept authoritative live, so `:w` has nothing to do -- absorb
        -- it (acwrite fires BufWriteCmd) and clear 'modified' so it reads as saved.
        vim.api.nvim_create_autocmd("BufWriteCmd", {
            buffer   = bufnr,
            callback = function()
                vim.bo[bufnr].modified = false
            end,
        })

        -- Since edits flow into the extmarks live and the buffer never needs
        -- writing, keep it perpetually unmodified: reset 'modified' the instant it
        -- is set. Without this, quitting with a pending edit prompts to save the
        -- scratch buffer (E37); the reset is synchronous, so the flag is already
        -- clear by the time `:q` runs its modified check.
        vim.api.nvim_create_autocmd("BufModifiedSet", {
            buffer   = bufnr,
            callback = function()
                if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified then
                    vim.bo[bufnr].modified = false
                end
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
