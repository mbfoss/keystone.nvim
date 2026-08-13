local M        = {}

-- Internal state and storage shared between the thin entry point
-- (`keystone.notes`) and the lazily-loaded commands (`keystone.notes.actions`).
-- Only startup modules are required here; the heavy UI modules live in `actions`.

local fsutil   = require("keystone.util.fsutil")
local extmarks = require("keystone.util.fileextmarks")

---@type keystone.util.fileextmarks.GroupFunctions
M.mark_group   = nil

---@type vim.api.keyset.set_extmark
M.mark_opts    = nil

---@type integer?  the scratch list buffer, when one has been opened
M.list_bufnr   = nil

---@type keystone.notes.Config
local _config

-- The note table is the source of truth for *which* notes exist and what they say.
-- An anchored note additionally mirrors into the extmark group under the same id,
-- which owns its line number from then on: extmarks follow in-buffer edits, the
-- table cannot. Unanchored notes have no extmark and live here alone.
---@type table<integer, keystone.notes.Note>
local _notes   = {}

local _next_id = 0

local function _new_id()
    _next_id = _next_id + 1
    return _next_id
end

---@return keystone.notes.Config
function M.default_config()
    ---@type keystone.notes.Config
    return {
        enabled      = true,
        persist_path = nil,
        sign_text    = "*",
        sign_hl      = "DiagnosticInfo",
    }
end

----------- STORE -----------
-- On-disk format, one note per non-empty line (blank lines ignored):
--
--     <note>[ -- <path>:<lnum>]
--
-- The note text comes first and is the only required part; the optional location
-- is everything after the *last* whitespace-surrounded ` -- `, and only when it
-- parses as `<path>:<lnum>`. Anything else is note text, so a line that fails to
-- name a location is still a perfectly good (unanchored) note rather than an error.
-- <path> is home-relative (`~/...`) under $HOME else absolute.
--
-- Disk is read once at startup and written only on exit (setup's VimLeavePre); the
-- interactive list is a scratch buffer rendered from the notes, and `:w` syncs edits
-- back without touching disk.

---@return string
function M.store_filepath()
    local pp = _config.persist_path
    if type(pp) == "function" then
        pp = pp()
    end
    if type(pp) == "string" and pp ~= "" then
        return vim.fs.normalize(pp)
    end
    return vim.fs.normalize("~/.nvimnotes")
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

---@param note keystone.notes.Note
---@return string
local function _encode_note(note)
    if note.file and note.lnum then
        return string.format("%s -- %s:%d", note.label, _encode_path(note.file), note.lnum)
    end
    return note.label
end

--- Parse one stored/list line. The greedy `(.*)` anchors on the *last*
--- whitespace-surrounded `--`, so a note reading `a -- b -- foo.lua:1` keeps
--- `a -- b` as its text. When the tail does not parse as `<path>:<lnum>` the
--- whole line is the note text -- only a blank line is rejected.
---@param line string
---@return keystone.notes.Note?
function M.decode_line(line)
    local label, loc = line:match("^(.*)%s+%-%-%s*(.-)%s*$")
    if label then
        local path, lnum = loc:match("^(.-):(%d+)$")
        if path and path ~= "" then
            label = label:match("^%s*(.-)%s*$")
            if label ~= "" then
                return { label = label, file = _decode_path(path), lnum = tonumber(lnum) }
            end
        end
    end

    label = line:match("^%s*(.-)%s*$")
    if label == "" then return nil end
    return { label = label }
end

---@return keystone.notes.Note[]
function M.store_load()
    local ok, raw = fsutil.read_content(M.store_filepath())
    if not ok or raw == "" then return {} end

    local notes = {}
    for line in raw:gmatch("[^\r\n]+") do
        local note = M.decode_line(line)
        if note then notes[#notes + 1] = note end
    end
    return notes
end

---@param notes keystone.notes.Note[]
---@return string[]
local function _encode_notes(notes)
    local lines = {}
    for _, n in ipairs(notes) do
        lines[#lines + 1] = _encode_note(n)
    end
    return lines
end

---@param notes keystone.notes.Note[]
local function _store_save(notes)
    local path = M.store_filepath()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

    local lines = _encode_notes(notes)
    local content = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
    fsutil.write_content(path, content)
end

---@param file string?
---@return string?
function M.norm(file)
    if not file or file == "" then return file end
    return vim.fn.fnamemodify(file, ":p")
end

----------- NOTES -----------

---@param label string
---@param file string?  absolute path; nil for an unanchored note
---@param lnum integer?
---@return integer id
function M.add(label, file, lnum)
    local id = _new_id()
    if file and lnum then
        file = M.norm(file)
        M.mark_group.set_file_extmark(id, file, lnum, 0, M.mark_opts, nil)
    else
        file, lnum = nil, nil
    end
    _notes[id] = { id = id, label = label, file = file, lnum = lnum }
    return id
end

---@param id integer
---@return boolean removed
function M.remove(id)
    if not _notes[id] then return false end
    _notes[id] = nil
    M.mark_group.remove_extmark(id)
    return true
end

function M.remove_all()
    _notes = {}
    M.mark_group.remove_extmarks()
end

---@param file string  absolute path
function M.remove_file(file)
    file = M.norm(file)
    for id, note in pairs(_notes) do
        if note.file == file then _notes[id] = nil end
    end
    M.mark_group.remove_file_extmarks(file)
end

---@return integer
function M.count()
    return vim.tbl_count(_notes)
end

-- Snapshot the notes. `live` (default true) reports current buffer positions for
-- anchored notes -- right for display, where marks follow in-buffer edits. Pass
-- false for the disk-consistent positions (synced on write/unload) used when
-- persisting. Unanchored notes are unaffected either way.
---@param live boolean?
---@return keystone.notes.Note[]
function M.read_notes(live)
    if live == nil then live = true end

    local lnums = {}
    for _, m in ipairs(M.mark_group.get_extmarks(live)) do
        lnums[m.id] = m.lnum
    end

    local notes = {}
    for id, note in pairs(_notes) do
        notes[#notes + 1] = {
            id    = id,
            label = note.label,
            file  = note.file,
            lnum  = note.file and (lnums[id] or note.lnum) or nil,
        }
    end
    return notes
end

-- Notes are ordered by their text: the note is the thing being looked for, and
-- the location -- when there is one -- only breaks ties between identical texts.
---@param live boolean?
---@return keystone.notes.Note[]
function M.sorted_notes(live)
    local notes = M.read_notes(live)
    table.sort(notes, function(a, b)
        if a.label ~= b.label then return a.label < b.label end
        if (a.file or "") ~= (b.file or "") then return (a.file or "") < (b.file or "") end
        if (a.lnum or 0) ~= (b.lnum or 0) then return (a.lnum or 0) < (b.lnum or 0) end
        return a.id < b.id
    end)
    return notes
end

--- The note anchored to `file`:`lnum`, if any.
---@param file string  absolute path
---@param lnum integer
---@return keystone.notes.Note?
function M.note_at(file, lnum)
    local mark = M.mark_group.get_extmark_by_location(M.norm(file), lnum, true)
    return mark and _notes[mark.id] or nil
end

----------- LIST BUFFER -----------

---@return integer?  the scratch list buffer, if it is currently loaded
local function _live_list_bufnr()
    local bufnr = M.list_bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
        return bufnr
    end
    return nil
end

-- Render the authoritative note snapshot into the scratch list buffer in place
-- (preserving cursor/view), leaving it unmodified. The notes always win, even over
-- unsaved edits; sync_from_buffer is the reverse path. No-op if the buffer isn't loaded.
function M.refresh_list()
    local bufnr = _live_list_bufnr()
    if not bufnr then return end

    local lines = _encode_notes(M.sorted_notes(false))

    local win = vim.fn.bufwinid(bufnr)
    local view = win >= 0 and vim.api.nvim_win_call(win, vim.fn.winsaveview) or nil

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modified = false

    if win >= 0 and view then
        vim.api.nvim_win_call(win, function()
            view.lnum = math.min(view.lnum, vim.api.nvim_buf_line_count(bufnr))
            vim.fn.winrestview(view)
        end)
    end
end

-- Reconcile the notes (and their signs) with the list buffer's lines: the buffer
-- wins. Only the delta is applied -- unchanged notes keep their ids and live
-- tracking, so the throttled per-edit sync doesn't churn every mark. Disk untouched.
---@param bufnr integer
function M.sync_from_buffer(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    vim.bo[bufnr].modified = false

    ---@param label string
    ---@param file string?
    ---@param lnum integer?
    ---@return string
    local function _key(label, file, lnum)
        return string.format("%s\0%s\0%d", label, file or "", lnum or 0)
    end

    -- The notes the buffer wants, as a multiset keyed by text+location so duplicate
    -- lines match one-for-one against existing notes. Every non-blank line parses
    -- (an unrecognised location is just part of the text), so nothing is dropped.
    local wanted = {}
    for _, line in ipairs(lines) do
        local n = M.decode_line(line)
        if n then
            local key = _key(n.label, n.file, n.lnum)
            local bucket = wanted[key]
            if bucket then
                bucket.count = bucket.count + 1
            else
                wanted[key] = { note = n, count = 1 }
            end
        end
    end

    -- Keep notes the buffer still wants (decrementing their bucket); drop the rest.
    -- Compare against stored positions -- the same snapshot the list is rendered from.
    for _, note in ipairs(M.read_notes(false)) do
        local bucket = wanted[_key(note.label, note.file, note.lnum)]
        if bucket and bucket.count > 0 then
            bucket.count = bucket.count - 1
        else
            M.remove(note.id)
        end
    end

    -- Whatever the buffer still wants had no matching note: add it.
    for _, bucket in pairs(wanted) do
        for _ = 1, bucket.count do
            local n = bucket.note
            local anchored = n.lnum ~= nil and n.lnum > 0
            M.add(n.label, anchored and n.file or nil, anchored and n.lnum or nil)
        end
    end
end

-- Serialize the authoritative note snapshot straight to the notes file. Called on
-- exit (VimLeavePre): during a session the notes are the single source of truth and
-- disk is left untouched.
function M.save_to_disk()
    if M.list_bufnr then
        M.sync_from_buffer(M.list_bufnr)
    end
    _store_save(M.sorted_notes(false))
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

-- Text of the line a note is being anchored to, offered as the default note text
-- so the prompt starts from something rather than empty. Only loaded buffers are
-- consulted -- the caller is sitting on the line.
---@param bufnr integer
---@param lnum integer  1-based
---@return string?  trimmed line text, nil when blank or out of range
function M.line_text(bufnr, lnum)
    if not vim.api.nvim_buf_is_loaded(bufnr) then return nil end
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    if not line then return nil end
    line = line:match("^%s*(.-)%s*$")
    return line ~= "" and line or nil
end

-- Initialise state from the effective config: define the extmark group and seed
-- the notes from the on-disk file. Idempotent -- the group is defined once.
---@param config keystone.notes.Config
function M.init(config)
    _config = config
    M.mark_opts = { sign_text = config.sign_text, sign_hl_group = config.sign_hl }

    if not M.mark_group then
        -- Claim the process-wide namespace/augroup prefix for this plugin before
        -- defining any group; the group name only has to be unique within keystone.
        extmarks.init("keystone")
        M.mark_group = extmarks.define_group("notes")

        for _, n in ipairs(M.store_load()) do
            M.add(n.label, n.file, n.lnum)
        end
    end
end

return M
