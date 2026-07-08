local M            = {}

-- Internal state and storage shared between the thin entry point
-- (`keystone.bookmarks`) and the lazily-loaded interactive commands
-- (`keystone.bookmarks.actions`). Only the modules needed at startup are
-- required here; the heavy UI modules live in `actions`.

local fsutil       = require("keystone.tk.fsutil")
local extmarks     = require("keystone.tk.extmarks")

---@type keystone.tk.extmarks.GroupFunctions
M.mark_group       = nil

---@type vim.api.keyset.set_extmark
M.mark_opts        = nil

---@type keystone.bookmarks.Config
local _config

local _next_id     = 0

local function _new_id()
    _next_id = _next_id + 1
    return _next_id
end
M.new_id = _new_id

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
-- The bookmarks file is a plain, human-editable text file. Each non-empty line is
--
--     <path>:<lnum>[  <label>]
--
-- where <path> is home-relative (`~/...`) when under $HOME, else absolute, and an
-- optional label follows the location after whitespace. Blank lines are ignored.

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
        return string.format("%s:%d  %s", rel, entry.lnum, entry.label)
    end
    return string.format("%s:%d", rel, entry.lnum)
end

---@param line string
---@return keystone.bookmarks.Entry?
function M.decode_line(line)
    -- Non-greedy path up to the first `:<digits>`; anything after is the label.
    local path, lnum, label = line:match("^%s*(.-):(%d+)%s*(.-)%s*$")
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
local function _store_save(entries)
    local path = M.store_filepath()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

    local lines = {}
    for _, e in ipairs(entries) do
        lines[#lines + 1] = _encode_entry(e)
    end
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

---@return integer?  the loaded bookmarks-store buffer, if one exists
local function _store_bufnr()
    local bufnr = vim.fn.bufnr(M.store_filepath())
    if bufnr >= 0 and vim.api.nvim_buf_is_loaded(bufnr) then return bufnr end
    return nil
end

-- Sync the extmark snapshot into the loaded store buffer in place (preserving the
-- cursor/view), then carry it through to disk via the buffer's own write. This
-- keeps the store buffer live-updated as bookmarks are added/removed while leaving
-- it clean and consistent with the file. `noautocmd` on the write avoids
-- re-triggering sync_from_file (which would needlessly rebuild the extmark group).
---@param bufnr integer
---@param entries keystone.bookmarks.Entry[]
local function _sync_store_buf(bufnr, entries)
    local lines = {}
    for _, e in ipairs(entries) do
        lines[#lines + 1] = _encode_entry(e)
    end

    local win = vim.fn.bufwinid(bufnr)
    local view = win >= 0 and vim.api.nvim_win_call(win, vim.fn.winsaveview) or nil

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent keepalt noautocmd write")
    end)

    if win >= 0 and view then
        vim.api.nvim_win_call(win, function()
            view.lnum = math.min(view.lnum, vim.api.nvim_buf_line_count(bufnr))
            vim.fn.winrestview(view)
        end)
    end
end

-- Push the authoritative extmark snapshot to the bookmarks store. The extmark
-- group is the single source of truth, and its relation to the store is
-- transitive: when the store buffer is loaded we sync into it and let the buffer
-- carry the change to disk (extmarks -> buffer -> disk), so an open list updates
-- live; otherwise we serialize straight to disk (extmarks -> disk). The buffer is
-- always driven from the extmarks, even if it has unsaved manual edits -- the
-- extmark group wins, and the reverse path (sync_from_file) is what lets a saved
-- edit of the list become authoritative instead.
function M.persist()
    local entries = M.sorted_entries(false)
    local bufnr = _store_bufnr()
    if bufnr then
        _sync_store_buf(bufnr, entries)
    else
        _store_save(entries)
    end
end

-- Rebuild the extmark group (the signs) from the bookmarks file on disk. This is
-- the "saving the file synchronises the signs" path: after the user edits and
-- writes the plain bookmarks file, its content becomes authoritative.
function M.sync_from_file()
    M.mark_group.remove_extmarks()
    for _, e in ipairs(M.store_load()) do
        M.mark_group.set_file_extmark(_new_id(), e.file, e.lnum, 0, M.mark_opts, { label = e.label })
    end
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
    M.persist()
end

---@param file string
---@param lnum integer
---@return boolean removed
function M.delete_loc(file, lnum)
    local mark = M.mark_group.get_extmark_by_location(file, lnum, true)
    if not mark then return false end
    M.mark_group.remove_extmark(mark.id)
    M.persist()
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
