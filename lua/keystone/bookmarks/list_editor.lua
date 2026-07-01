local M         = {}

local inputwin  = require("keystone.util.inputwin")
local uitool    = require("keystone.util.uitool")
local floatwin  = require("keystone.util.floatwin")

---@class keystone.bookmarks.list_editor.Api
---@field get_entries fun():keystone.bookmarks.Entry[]
---@field delete fun(file:string, lnum:integer)
---@field upsert fun(name:string, file:string, lnum:integer)
---@field subscribe fun(fn:fun()):fun()  -- returns an unsubscribe function

---@class keystone.bookmarks.list_editor.Item
---@field name string   -- current name
---@field file string   -- absolute path
---@field lnum integer  -- 1-based line number

local _ns       = vim.api.nvim_create_namespace("keystone_bookmarks_list")

-- ── State for the single active editor ────────────────────────────────────────

---@type keystone.bookmarks.list_editor.Api?
local _api

---@type integer?
local _bufnr

---@type integer?
local _win

---@type integer?
local _augroup

---@type fun()?
local _unsubscribe

---@type keystone.bookmarks.list_editor.Item[]?
local _items

-- Stack of inverse edits. Each entry is an upsert that restores a prior state:
-- undoing a removal re-adds the bookmark, undoing a rename restores the old name.
---@type keystone.bookmarks.list_editor.Item[]?
local _undo

-- One-shot cursor target for the next refresh (the location an edit should land on).
---@type string?
local _pending_focus_loc

local _closed            = false
local _refresh_scheduled = false

---@param file string
---@param lnum integer
---@return string
local function _loc(file, lnum)
    return file .. "\0" .. lnum
end

local function _teardown()
    if _unsubscribe then
        _unsubscribe()
        _unsubscribe = nil
    end
    if _augroup then
        vim.api.nvim_del_augroup_by_id(_augroup)
        _augroup = nil
    end
    if _bufnr and vim.api.nvim_buf_is_valid(_bufnr) then
        vim.api.nvim_buf_delete(_bufnr, { force = true })
    end
    _api               = nil
    _bufnr             = nil
    _win               = nil
    _items             = nil
    _undo              = nil
    _pending_focus_loc = nil
end

local function _render()
    if not _items or not _bufnr or not vim.api.nvim_buf_is_valid(_bufnr) then return end

    local lines = {}
    if #_items == 0 then
        lines[1] = "(no bookmarks — :q to close)"
    else
        for _, item in ipairs(_items) do
            local rel = vim.fn.fnamemodify(item.file, ":~:.")
            lines[#lines + 1] = string.format("%s  %s:%d", item.name, rel, item.lnum)
        end
    end

    vim.bo[_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(_bufnr, 0, -1, false, lines)
    vim.bo[_bufnr].modifiable = false

    vim.api.nvim_buf_clear_namespace(_bufnr, _ns, 0, -1)
    if #_items == 0 then
        vim.api.nvim_buf_set_extmark(_bufnr, _ns, 0, 0, {
            end_col = #lines[1], hl_group = "Comment",
        })
        return
    end
    for row, item in ipairs(_items) do
        local name_len = #item.name
        vim.api.nvim_buf_set_extmark(_bufnr, _ns, row - 1, 0, {
            end_col = name_len, hl_group = "Identifier",
        })
        vim.api.nvim_buf_set_extmark(_bufnr, _ns, row - 1, name_len, {
            end_col = #lines[row], hl_group = "Comment",
        })
    end
end

local function _resize()
    if not _items or not _win or not vim.api.nvim_win_is_valid(_win) then return end
    local count = math.max(1, #_items)
    vim.api.nvim_win_set_height(_win, math.min(count, 12))
end

---@return keystone.bookmarks.list_editor.Item?
local function _cur_item()
    if not _win or not vim.api.nvim_win_is_valid(_win) or not _items or #_items == 0 then return nil end
    local row = vim.api.nvim_win_get_cursor(_win)[1]
    return _items[row]
end

-- Rebuild the list from the store, preserving the cursor on its bookmark (or on
-- the pending focus target set by the most recent edit).
local function _refresh()
    if _closed or not _api or not _bufnr or not vim.api.nvim_buf_is_valid(_bufnr) then return end

    local win_ok   = _win and vim.api.nvim_win_is_valid(_win)
    local prev_row = win_ok and vim.api.nvim_win_get_cursor(_win)[1] or 1

    local prev_loc = _pending_focus_loc
    if not prev_loc and _items then
        local cur = _items[prev_row]
        if cur then prev_loc = _loc(cur.file, cur.lnum) end
    end
    _pending_focus_loc = nil

    local entries = _api.get_entries()
    table.sort(entries, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.lnum < b.lnum
    end)
    _items = {}
    for _, e in ipairs(entries) do
        _items[#_items + 1] = { name = e.name, file = e.file, lnum = e.lnum }
    end

    _render()
    _resize()

    if #_items > 0 and win_ok then
        local target
        if prev_loc then
            for i, item in ipairs(_items) do
                if _loc(item.file, item.lnum) == prev_loc then
                    target = i
                    break
                end
            end
        end
        target = target or math.min(prev_row, #_items)
        vim.api.nvim_win_set_cursor(_win, { math.max(1, target), 0 })
    end
end

-- Store mutations fire synchronously and may originate from other windows or
-- fast contexts, so coalesce and defer the resulting refresh.
local function _schedule_refresh()
    if _closed or _refresh_scheduled then return end
    _refresh_scheduled = true
    vim.schedule(function()
        _refresh_scheduled = false
        _refresh()
    end)
end

local function _open_file()
    local item = _cur_item()
    if not item then return end
    uitool.smart_open_file(item.file, item.lnum, 0)
end

local function _remove()
    local item = _cur_item()
    if not item or not _api or not _undo then return end
    _undo[#_undo + 1] = { name = item.name, file = item.file, lnum = item.lnum }
    _api.delete(item.file, item.lnum) -- emits change -> refresh
end

local function _rename()
    local item = _cur_item()
    if not item then return end
    local file, lnum, old_name = item.file, item.lnum, item.name
    inputwin.open({ prompt = "Rename bookmark", default = old_name }, function(name)
        if not name then return end
        name = name:match("^%s*(.-)%s*$")
        if name == "" or name == old_name then return end
        if not _api or not _undo then return end -- editor closed while prompting
        _undo[#_undo + 1] = { name = old_name, file = file, lnum = lnum }
        _pending_focus_loc = _loc(file, lnum)
        _api.upsert(name, file, lnum) -- emits change -> refresh
    end)
end

local function _undo_last()
    if not _api or not _undo or #_undo == 0 then
        vim.api.nvim_echo({ { "Nothing to undo" } }, false, {})
        return
    end
    local op = table.remove(_undo)
    if not op then return end
    _pending_focus_loc = _loc(op.file, op.lnum)
    _api.upsert(op.name, op.file, op.lnum) -- re-add or restore name; emits refresh
end

---@class keystone.bookmarks.list_editor.Keymap
---@field label string    -- key(s) shown in the help menu
---@field keys string[]   -- keys to bind
---@field desc string     -- help description
---@field fn fun()

local _show_help -- forward declaration; the help menu is built from _keymaps()

--- The single source of truth for both the bindings and the help menu, so they
--- can never drift apart.
---@return keystone.bookmarks.list_editor.Keymap[]
local function _keymaps()
    return {
        { label = "<CR>",      keys = { "<CR>" },       desc = "Open bookmark",    fn = _open_file },
        { label = "d",         keys = { "d" },          desc = "Remove bookmark",  fn = _remove },
        { label = "r",         keys = { "r" },          desc = "Rename bookmark",  fn = _rename },
        { label = "u",         keys = { "u" },          desc = "Undo last change", fn = _undo_last },
        { label = "g?",        keys = { "g?" },         desc = "Show this help",   fn = function() _show_help() end },
    }
end

--- Opens a floating cheat-sheet of the active keymaps.
function _show_help()
    local maps = _keymaps()
    local key_width = 0
    for _, m in ipairs(maps) do
        key_width = math.max(key_width, #m.label)
    end

    local lines = {}
    for _, m in ipairs(maps) do
        lines[#lines + 1] = string.format("  %-" .. key_width .. "s   %s", m.label, m.desc)
    end

    floatwin.open(table.concat(lines, "\n"), {
        title = "Bookmarks keymaps",
    })
end

---@param api keystone.bookmarks.list_editor.Api
function M.open(api)
    if _win and vim.api.nvim_win_is_valid(_win) then
        vim.api.nvim_set_current_win(_win)
        return
    end

    if #api.get_entries() == 0 then
        vim.notify("[keystone] No bookmarks set", vim.log.levels.WARN)
        return
    end

    _api               = api
    _items             = {}
    _undo              = {}
    _pending_focus_loc = nil
    _closed            = false
    _refresh_scheduled = false

    _bufnr = uitool.create_scratch_buffer(false, { modifiable = false })
    vim.api.nvim_buf_set_name(_bufnr, "keystone://bookmarks-editor")

    vim.cmd("botright split")
    _win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(_win, _bufnr)

    vim.wo[_win].number         = false
    vim.wo[_win].relativenumber = false
    vim.wo[_win].wrap           = false
    vim.wo[_win].spell          = false
    vim.wo[_win].signcolumn     = "no"
    vim.wo[_win].cursorline     = true
    vim.wo[_win].winfixheight   = true
    vim.wo[_win].winfixbuf      = true

    local kopts = { buffer = _bufnr, nowait = true, silent = true }
    for _, m in ipairs(_keymaps()) do
        for _, key in ipairs(m.keys) do
            vim.keymap.set("n", key, m.fn, kopts)
        end
    end

    _augroup = vim.api.nvim_create_augroup("keystone_bookmarks_list", { clear = true })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = _augroup,
        callback = function(args)
            if tonumber(args.match) == _win then
                _closed = true
                _teardown()
            end
        end,
    })

    _unsubscribe = api.subscribe(_schedule_refresh)

    _refresh()
end

return M
