---@class keystone.bookmarks.actions
local M           = {}

-- Interactive bookmark commands. This module pulls in the heavy UI modules
-- (inputwin, ui, fixedwin) and is required only the first time a command runs,
-- keeping startup cheap. `keystone.bookmarks` forwards to these on demand.

local core     = require("keystone.bookmarks.core")
local throttle = require("keystone.util.throttle")
local inputwin = require("keystone.util.inputwin")
local ui       = require("keystone.util.ui")
local fixedwin = require("keystone.util.fixedwin")

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

-- Scratch buffer holding the on-disk preview of the highlighted bookmark. Its
-- default 'bufhidden' wipes it as soon as another buffer takes over the preview
-- window, so it is recreated on demand and never outlives the picker.
local _preview_bufnr = nil

-- How much of a bookmarked file is read for the preview. The window shows a
-- screenful; the rest only matters for a bookmark near the top of a big file.
local _PREVIEW_LINES = 500

--- Buffer to preview `entry` in, for `vim.ui.select` implementations that
--- support `preview_item` (`keystone.select` does). A file already open in
--- Neovim is previewed through its own buffer, so unsaved edits show; anything
--- else is read from disk into a scratch buffer rather than loaded as a real
--- buffer -- loading would fire the whole autocmd chain and prompt on a stale
--- swap file.
---@param entry keystone.bookmarks.Entry
---@return keystone.select.Preview?
local function _preview_bookmark(entry)
    local open = vim.fn.bufnr("^" .. entry.file .. "$")
    if open ~= -1 and vim.api.nvim_buf_is_loaded(open) then
        return { buf = open, pos = { entry.lnum, 0 } }
    end

    local stat = vim.uv.fs_stat(entry.file)
    if not stat or stat.type ~= "file" then return nil end

    if not (_preview_bufnr and vim.api.nvim_buf_is_valid(_preview_bufnr)) then
        _preview_bufnr = ui.create_scratch_buffer(false, {})
    end
    vim.api.nvim_buf_set_lines(_preview_bufnr, 0, -1, false,
        vim.fn.readfile(entry.file, "", _PREVIEW_LINES))
    -- 'syntax', not 'filetype': no FileType autocmd fires, so treesitter and the
    -- LSP never attach to what is only a preview.
    vim.bo[_preview_bufnr].syntax = vim.filetype.match({ filename = entry.file }) or ""

    return { buf = _preview_bufnr, pos = { entry.lnum, 0 } }
end

--- The bookmark list as a picker: fuzzy over the location *and* the label, so a
--- bookmark can be found by words in its note, with the bookmarked line shown in
--- the preview.
function M.pick()
    local entries = core.sorted_entries()
    if #entries == 0 then
        vim.notify("[keystone] No bookmarks set", vim.log.levels.WARN)
        return
    end

    ---@type keystone.select.Opts
    local opts = {
        prompt       = "Bookmarks",
        ---@param entry keystone.bookmarks.Entry
        format_item  = function(entry)
            local loc = vim.fn.fnamemodify(entry.file, ":~:.") .. ":" .. entry.lnum
            return entry.label and (loc .. "  " .. entry.label) or loc
        end,
        preview_item = _preview_bookmark,
    }

    vim.ui.select(entries, opts, function(entry)
        if entry then ui.smart_open_file(entry.file, entry.lnum, 0) end
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

        -- `acwrite`, not `nofile`: keeps the no-disk-backing scratch semantics but
        -- gives the buffer a name, so `:w` is a clean no-op instead of E32. Syncing
        -- doesn't depend on `:w` -- edits flow to the extmarks (throttled TextChanged).
        local name = "keystone://bookmarks"
        local existing = vim.fn.bufnr(name)
        if existing ~= -1 and existing ~= bufnr then
            vim.api.nvim_buf_delete(existing, { force = false })
        end
        vim.api.nvim_buf_set_name(bufnr, name)
        vim.bo[bufnr].buftype = "acwrite"
        vim.bo[bufnr].bufhidden = "hide"
        vim.bo[bufnr].swapfile = false

        -- custom completion function
        vim.bo[bufnr].completefunc = "v:lua.require'keystone.bookmarks.actions'.complete_path"

        -- Push edited lines back into the extmarks as the user edits, throttled so a
        -- burst rebuilds the group at most once per window. Only syncs (no refresh_list):
        -- re-rendering the sorted form mid-edit would fight the cursor (done on next open).
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

        -- Edits flow into the extmarks live and the buffer never needs writing, so keep
        -- it perpetually unmodified: reset 'modified' the instant it's set. Otherwise
        -- quitting with a pending edit prompts to save (E37); the reset is synchronous.
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
