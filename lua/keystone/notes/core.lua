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
-- On-disk format, one note per non-empty line (blank lines ignored). A note is
-- free text; a location is an `@` reference sitting anywhere inside it:
--
--     off-by-one in @~/src/parser.lua:19 -- check the bounds
--     the whole tokenizer needs a rewrite: @~/src/lexer.lua
--     ask the team about cache invalidation
--
-- The reference is `@<path>` with an optional `:<lnum>`, and must start a token
-- (preceded by whitespace or the line start) so an address like bob@example.com
-- is left alone. The first reference in the line wins; everything else, `@` or
-- not, is just text. <path> is home-relative (`~/...`) under $HOME else absolute.
--
-- The reference stays part of the note text rather than being split off, so a note
-- is stored exactly as it reads. Internally the surrounding text is kept as
-- `prefix`/`suffix` and the reference is re-rendered from the *current* file and
-- line, which is what lets an extmark's drift rewrite the `:<lnum>` in the text.
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

--- Render a note's text: the surrounding text with its `@` reference rebuilt from
--- the current file and line. Anchored notes are re-rendered rather than stored as
--- one string so that a line number tracked by an extmark stays true in the text.
---@param prefix string
---@param file string?
---@param lnum integer?
---@param suffix string
---@return string
local function _render(prefix, file, lnum, suffix)
    if not file then return prefix end
    local ref = "@" .. _encode_path(file)
    if lnum then ref = ref .. ":" .. lnum end
    return prefix .. ref .. suffix
end

M.render = _render

--- Every `@` reference in `text`, in order. Only a reference starting a token
--- counts, so `bob@example.com` is text and `@bob/notes.md` is a path. A note may
--- mention several files even though only the first one anchors it -- the others
--- are still real references, and `<CR>` in the list follows whichever the cursor
--- is on (see `ref_at`).
---@param text string
---@return keystone.notes.Ref[]
local function _refs(text)
    local refs = {}
    for pos, token in text:gmatch("()(@%S+)") do
        local start = pos --[[@as integer]]
        if start == 1 or text:sub(start - 1, start - 1):match("%s") then
            -- Split a trailing `:<digits>` off the path. Greedy, so the colons in a
            -- path like `@a:b:10` stay with the path and only `10` is the line.
            local path, lnum = token:match("^@(.*):(%d+)$")
            if not path or path == "" then
                path, lnum = token:sub(2), nil
            end
            if path ~= "" and path ~= "@" then
                refs[#refs + 1] = {
                    start = start,
                    stop  = start + #token - 1,
                    path  = path,
                    file  = _decode_path(path),
                    lnum  = lnum and tonumber(lnum) or nil,
                }
            end
        end
    end
    return refs
end

M.refs = _refs

--- The first reference in `text`, which is the one that anchors the note.
---@param text string
---@return integer? start, integer? stop, string? path, integer? lnum
local function _find_ref(text)
    local ref = _refs(text)[1]
    if not ref then return nil end
    return ref.start, ref.stop, ref.path, ref.lnum
end

M.find_ref = _find_ref

--- The reference sitting under `col`, if the cursor is on one at all. Byte column,
--- 1-based, as `nvim_win_get_cursor` reports it plus one.
---@param text string
---@param col integer
---@return keystone.notes.Ref?
function M.ref_at(text, col)
    for _, ref in ipairs(_refs(text)) do
        if col >= ref.start and col <= ref.stop then return ref end
    end
    return nil
end

--- Parse one stored/list line into a note. Every non-blank line is a valid note:
--- an `@` reference anchors it, and its absence simply means the note has no
--- location. Only a blank line is rejected.
---@param line string
---@return keystone.notes.Note?
function M.decode_line(line)
    local text = line:match("^%s*(.-)%s*$")
    if text == "" then return nil end

    -- The first reference anchors the note; any others are simply part of its text.
    local ref = _refs(text)[1]
    if not ref then
        return { label = text, prefix = text, suffix = "" }
    end

    local prefix, suffix = text:sub(1, ref.start - 1), text:sub(ref.stop + 1)
    return {
        label  = _render(prefix, ref.file, ref.lnum, suffix),
        prefix = prefix,
        suffix = suffix,
        file   = ref.file,
        lnum   = ref.lnum,
    }
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

-- A note's rendered text is exactly its stored/list line, so there is nothing to
-- encode beyond collecting the labels.
---@param notes keystone.notes.Note[]
---@return string[]
local function _encode_notes(notes)
    local lines = {}
    for _, n in ipairs(notes) do
        lines[#lines + 1] = n.label
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

--- Add a note from a decoded line (see `decode_line`). Only a note naming both a
--- file *and* a line gets an extmark: a file-only reference has no line to sign or
--- to track, so it is held in the table alone, as an unanchored note is.
---@param note keystone.notes.Note
---@return integer id
function M.add(note)
    local id = _new_id()
    local file = note.file and M.norm(note.file) or nil
    local lnum = file and note.lnum or nil

    if file and lnum then
        M.mark_group.set_file_extmark(id, file, lnum, 0, M.mark_opts, nil)
    end

    _notes[id] = {
        id     = id,
        prefix = note.prefix or note.label or "",
        suffix = note.suffix or "",
        file   = file,
        lnum   = lnum,
    }
    return id
end

--- Add a note reading `text` with a reference to `file`(`:lnum`) appended -- the
--- shape `:Note add` produces, where the location comes from the cursor rather
--- than from anything the user typed.
---@param text string
---@param file string?
---@param lnum integer?
---@return integer id
function M.add_at(text, file, lnum)
    local prefix = (file and text ~= "") and (text .. " ") or text
    return M.add({ prefix = prefix, suffix = "", file = file, lnum = lnum })
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
        local lnum = note.file and (lnums[id] or note.lnum) or nil
        notes[#notes + 1] = {
            id     = id,
            label  = _render(note.prefix, note.file, lnum, note.suffix),
            prefix = note.prefix,
            suffix = note.suffix,
            file   = note.file,
            lnum   = lnum,
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

    -- The notes the buffer wants, as a multiset so duplicate lines match one-for-one
    -- against existing notes. A note's rendered label *is* its line, reference and
    -- all, so the label alone identifies it. Every non-blank line parses -- text that
    -- names no location is simply an unanchored note -- so nothing is dropped.
    local wanted = {}
    for _, line in ipairs(lines) do
        local n = M.decode_line(line)
        if n then
            local bucket = wanted[n.label]
            if bucket then
                bucket.count = bucket.count + 1
            else
                wanted[n.label] = { note = n, count = 1 }
            end
        end
    end

    -- Keep notes the buffer still wants (decrementing their bucket); drop the rest.
    -- Compare against stored positions -- the same snapshot the list is rendered from.
    for _, note in ipairs(M.read_notes(false)) do
        local bucket = wanted[note.label]
        if bucket and bucket.count > 0 then
            bucket.count = bucket.count - 1
        else
            M.remove(note.id)
        end
    end

    -- Whatever the buffer still wants had no matching note: add it.
    for _, bucket in pairs(wanted) do
        for _ = 1, bucket.count do
            M.add(bucket.note)
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
            M.add(n)
        end
    end
end

return M
