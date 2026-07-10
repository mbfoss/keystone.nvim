local M        = {}

-- Internal state and storage shared between the thin entry point
-- (`keystone.bookmarks`) and the lazily-loaded interactive commands
-- (`keystone.bookmarks.actions`). Only the modules needed at startup are
-- required here; the heavy UI modules live in `actions`.

local fsutil   = require("keystone.tk.fsutil")
local extmarks = require("keystone.tk.extmarks")

local diagnostic = vim.diagnostic

---@type keystone.tk.extmarks.GroupFunctions
M.mark_group   = nil

---@type vim.api.keyset.set_extmark
M.mark_opts    = nil

---@type integer?  the scratch list buffer, when one has been opened
M.list_bufnr   = nil

---@type keystone.bookmarks.Config
local _config

local _next_id = 0

local function _new_id()
    _next_id = _next_id + 1
    return _next_id
end
M.new_id = _new_id

-- Namespace for the "this list line doesn't parse" hints (see _mark_invalid_lines).
-- Kept separate from the sign extmark group so it can be cleared independently.
local _invalid_ns = vim.api.nvim_create_namespace("keystone_bookmarks_invalid")

-- Flag every non-blank list line that does not parse as
-- `<path>:<lnum>[ -- label]`, so a typo shows up as an inline warning instead of
-- silently dropping the bookmark on the next sync. `rows` are 0-based; the whole
-- namespace is recomputed from scratch each call.
---@param bufnr integer
---@param rows integer[]
local function _mark_invalid_lines(bufnr, rows)
    local diagnostics = {}

    for _, row in ipairs(rows) do
        diagnostics[#diagnostics + 1] = {
            lnum = row,
            col = 0,
            severity = diagnostic.severity.ERROR,
            source = "keystone-bookmarks",
            message = "expected path:line [ -- label]",
        }
    end

    diagnostic.set(_invalid_ns, bufnr, diagnostics)
end

---@return keystone.bookmarks.Config
function M.default_config()
    ---@type keystone.bookmarks.Config
    return {
        enabled      = true,
        persist_path = nil,
        sign_text    = "*",
        sign_hl      = "DiagnosticInfo",
    }
end

----------- STORE -----------
-- The bookmarks file is a plain text file. Each non-empty line is
--
--     <path>:<lnum>[ -- <label>]
--
-- where <path> is home-relative (`~/...`) when under $HOME, else absolute, and an
-- optional label follows the location after a ` -- ` separator. The explicit
-- separator keeps colons/digits in the label from confusing the location parse.
-- Blank lines are ignored.
--
-- The extmark group is the single source of truth in memory. The file on disk is
-- read once at startup and written only on exit (see setup's VimLeavePre). The
-- interactive list (see actions.open_list) is a scratch buffer rendered from the
-- extmarks -- never the file itself -- and writing it (`:w`) syncs the edited
-- lines back into the extmark group without touching disk.

---@return string
function M.store_filepath()
    local pp = _config.persist_path
    if type(pp) == "function" then
        pp = pp()
    end
    if type(pp) == "string" and pp ~= "" then
        return vim.fs.normalize(pp)
    end
    return vim.fs.normalize("~/.nvimbookmarks")
end

---@param file string  absolute path
---@return string      home-relative when under $HOME, else absolute
local function _encode_path(file)
    return vim.fn.fnamemodify(file, ":~")
end

---@param path string  as written in the file (may be `~`-relative or relative)
---@return string      absolute path
local function _decode_path(path)
    return vim.fn.fnamemodify(vim.fs.normalize(path), ":p")
end

---@param entry keystone.bookmarks.Entry
---@return string
local function _encode_entry(entry)
    local rel = _encode_path(entry.file)
    if entry.label and entry.label ~= "" then
        return string.format("%s:%d -- %s", rel, entry.lnum, entry.label)
    end
    return string.format("%s:%d", rel, entry.lnum)
end

---@param line string
---@return keystone.bookmarks.Entry?
function M.decode_line(line)
    -- Split off an optional ` -- <label>` note first (on the first *whitespace-
    -- surrounded* `--`), so colons/digits in the label can't confuse the
    -- `<path>:<lnum>` parse. Requiring the space before `--` (not `%s*`) means a
    -- bare `--` inside a filename, e.g. `foo--bar.lua:10`, is left in the path
    -- rather than being mistaken for the label separator.
    local loc, label = line:match("^(.-)%s+%-%-%s*(.-)%s*$")
    if not loc then loc = line end
    local path, lnum = loc:match("^%s*(.-):(%d+)%s*$")
    if not path or path == "" then return nil end
    if label == "" then label = nil end
    return { file = _decode_path(path), lnum = tonumber(lnum), label = label }
end

---@return keystone.bookmarks.Entry[]
function M.store_load()
    local ok, raw = fsutil.read_content(M.store_filepath())
    if not ok or raw == "" then return {} end

    local entries = {}
    for line in raw:gmatch("[^\r\n]+") do
        local entry = M.decode_line(line)
        if entry then entries[#entries + 1] = entry end
    end
    return entries
end

---@param entries keystone.bookmarks.Entry[]
---@return string[]
local function _encode_entries(entries)
    local lines = {}
    for _, e in ipairs(entries) do
        lines[#lines + 1] = _encode_entry(e)
    end
    return lines
end

---@param entries keystone.bookmarks.Entry[]
local function _store_save(entries)
    local path = M.store_filepath()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

    local lines = _encode_entries(entries)
    local content = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
    fsutil.write_content(path, content)
end

function M.norm(file)
    if not file or file == "" then return file end
    return vim.fn.fnamemodify(file, ":p")
end

-- Snapshot the group's bookmarks. `live` (default true) reports current buffer
-- positions -- right for display, where marks follow in-buffer edits. Pass false
-- for the disk-consistent positions (synced on write/unload) used when persisting.
---@param live boolean?
---@return keystone.bookmarks.Entry[]
function M.read_entries(live)
    if live == nil then live = true end
    local marks = M.mark_group.get_extmarks(live)
    local entries = {}
    for _, m in ipairs(marks) do
        entries[#entries + 1] = {
            file  = m.file,
            lnum  = m.lnum,
            label = m.user_data and m.user_data.label or nil,
        }
    end
    return entries
end

---@return keystone.bookmarks.Entry[]
function M.sorted_entries(live)
    local entries = M.read_entries(live)
    table.sort(entries, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.lnum < b.lnum
    end)
    return entries
end

---@return integer?  the scratch list buffer, if it is currently loaded
local function _live_list_bufnr()
    local bufnr = M.list_bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
        return bufnr
    end
    return nil
end

-- Render the authoritative extmark snapshot into the scratch list buffer in place
-- (preserving the cursor/view) and leave it unmodified. Interactive changes call
-- this so an open list stays in step with the extmarks; the buffer is always
-- driven from the extmarks, even if it has unsaved manual edits -- the extmark
-- group wins, and the reverse path (sync_from_buffer) is what lets a saved edit of
-- the list become authoritative instead. No-op when the list buffer is not loaded;
-- disk is untouched (the file is written only on exit -- see save_to_disk).
function M.refresh_list()
    local bufnr = _live_list_bufnr()
    if not bufnr then return end

    local lines = _encode_entries(M.sorted_entries(false))

    local win = vim.fn.bufwinid(bufnr)
    local view = win >= 0 and vim.api.nvim_win_call(win, vim.fn.winsaveview) or nil

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modified = false
    -- The rendered lines are the canonical form, so none are invalid: drop any
    -- lingering "invalid line" hints from a prior edit.
    vim.api.nvim_buf_clear_namespace(bufnr, _invalid_ns, 0, -1)

    if win >= 0 and view then
        vim.api.nvim_win_call(win, function()
            view.lnum = math.min(view.lnum, vim.api.nvim_buf_line_count(bufnr))
            vim.fn.winrestview(view)
        end)
    end
end

-- Reconcile the extmark group (the signs) with the scratch list buffer's lines.
-- This is the "editing the list synchronises the signs" path: the buffer content
-- becomes authoritative. Rather than tearing the whole group down and rebuilding it,
-- only the delta is applied -- marks whose (file, line, label) still appears in the
-- buffer are left untouched, so they keep their ids and live in-buffer tracking;
-- vanished marks are removed and new lines are added. This matters because the sync
-- runs on every edit (throttled), so a full rebuild would needlessly churn every
-- mark on each keystroke. Disk is not touched -- the file is written only on exit.
---@param bufnr integer
function M.sync_from_buffer(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    vim.bo[bufnr].modified = false
    ---@param file string
    ---@param lnum integer
    ---@param label string?
    ---@return string
    local function _key(file, lnum, label)
        return string.format("%s\0%d\0%s", file, lnum, label or "")
    end

    -- The lines the buffer wants, as a multiset keyed by location+label so that
    -- duplicate entries are matched one-for-one against existing marks. Non-blank
    -- lines that fail to parse are collected so they can be flagged in place
    -- rather than silently discarded.
    local wanted = {}
    local invalid = {}
    for i, line in ipairs(lines) do
        local e = M.decode_line(line)
        if e then
            local key = _key(e.file, e.lnum, e.label)
            local bucket = wanted[key]
            if bucket then
                bucket.count = bucket.count + 1
            else
                wanted[key] = { entry = e, count = 1 }
            end
        elseif line:match("%S") then
            invalid[#invalid + 1] = i - 1 -- 0-based row
        end
    end
    _mark_invalid_lines(bufnr, invalid)

    -- Keep marks the buffer still wants (decrementing their bucket); drop the rest.
    -- Compare against stored positions -- the same snapshot the list is rendered from.
    for _, m in ipairs(M.mark_group.get_extmarks(false)) do
        local label = m.user_data and m.user_data.label or nil
        local bucket = wanted[_key(m.file, m.lnum, label)]
        if bucket and bucket.count > 0 then
            bucket.count = bucket.count - 1
        else
            M.mark_group.remove_extmark(m.id)
        end
    end

    -- Whatever the buffer still wants had no matching mark: add it.
    for _, bucket in pairs(wanted) do
        for _ = 1, bucket.count do
            local e = bucket.entry
            if e.lnum and e.lnum > 0 then
                M.mark_group.set_file_extmark(_new_id(), e.file, e.lnum, 0, M.mark_opts, { label = e.label })
            end
        end
    end
end

-- Serialize the authoritative extmark snapshot straight to the bookmarks file.
-- Called on exit (VimLeavePre): during a session the extmarks are the single
-- source of truth and disk is left untouched.
function M.save_to_disk()
    if M.list_bufnr then
        M.sync_from_buffer(M.list_bufnr)
    end
    _store_save(M.sorted_entries(false))
end

---@return string|nil,number|nil
function M.get_cur_loc()
    local bufnr = vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    if vim.bo[bufnr].buftype ~= '' then
        return
    end
    -- Use the buffer name (not expand("%:p")): the extmarks group keys marks by
    -- nvim_buf_get_name, and on symlinked paths the two disagree, which would
    -- desync mark tracking. Matches clear_file, which already uses the buf name.
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file == "" then
        return
    end
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    return file, lnum
end

---@param file string
---@param lnum integer
---@param label string?
function M.upsert(file, lnum, label)
    local by_loc = M.mark_group.get_extmark_by_location(file, lnum, true)
    if by_loc then
        M.mark_group.remove_extmark(by_loc.id)
    end

    M.mark_group.set_file_extmark(_new_id(), file, lnum, 0, M.mark_opts, { label = label })
    M.refresh_list()
end

---@param file string
---@param lnum integer
---@return boolean removed
function M.delete_loc(file, lnum)
    local mark = M.mark_group.get_extmark_by_location(file, lnum, true)
    if not mark then return false end
    M.mark_group.remove_extmark(mark.id)
    M.refresh_list()
    return true
end

-- Initialise state from the effective config: define the extmark group and seed
-- it from the on-disk bookmarks file. Idempotent -- the group is defined once.
---@param config keystone.bookmarks.Config
function M.init(config)
    _config = config
    M.mark_opts = { sign_text = config.sign_text, sign_hl_group = config.sign_hl }

    if not M.mark_group then
        M.mark_group = extmarks.define_group("keystone_bookmarks_ext", { priority = 20 })

        for _, e in ipairs(M.store_load()) do
            M.mark_group.set_file_extmark(_new_id(), e.file, e.lnum, 0, M.mark_opts, { label = e.label })
        end
    end
end

return M
