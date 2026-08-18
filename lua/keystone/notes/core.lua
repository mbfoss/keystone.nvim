local M      = {}

-- Internal state shared between the thin entry point (`keystone.notes`) and the
-- lazily-loaded commands (`keystone.notes.actions`). Only startup modules are
-- required here; the heavy UI modules live in `actions`.

local fsutil = require("keystone.util.fsutil")

---@type keystone.notes.Config
local _config

---@return keystone.notes.Config
function M.default_config()
    ---@type keystone.notes.Config
    return {
        enabled      = true,
        persist_path = nil,
    }
end

----------- STORE -----------
-- The notes file is an ordinary text file, one note per non-empty line. A note is
-- free text; a location is an `@` reference sitting anywhere inside it:
--
--     @/home/me/src/parser.lua:19 off-by-one -- check the bounds
--     the whole tokenizer needs a rewrite: @/home/me/src/lexer.lua
--     ask the team about cache invalidation
--
-- The reference is `@<path>` with an optional `:<lnum>`, and must start a token
-- (preceded by whitespace or the line start) so an address like bob@example.com
-- is left alone. The first reference in the line wins; everything else, `@` or
-- not, is just text.
--
-- Paths are absolute *in the file*: one notes file serves every directory it is
-- opened from, so a note has to mean the same file wherever it is read. In the buffer
-- they are shown relative to the cwd where that shortens them (`to_display` /
-- `to_stored` convert between the two, and `refresh_display` re-renders on a cwd
-- change).
--
-- `:Notes add` appends a line. `:Notes list` shows the notes in a scratch buffer --
-- not a buffer editing the file -- whose lines are the session's working copy;
-- `save_buffer` writes them back. Deleting a note is deleting its line.

---@return string
function M.store_filepath()
    local pp = _config and _config.persist_path
    if type(pp) == "function" then
        pp = pp()
    end
    if type(pp) == "string" and pp ~= "" then
        return vim.fs.normalize(pp)
    end
    return vim.fs.normalize("~/.nvimnotes")
end

---@param path string  as written (may be `~`-relative or cwd-relative)
---@return string      absolute path
local function _decode_path(path)
    return vim.fn.fnamemodify(vim.fs.normalize(path), ":p")
end

--- `file` relative to the cwd, or nil when it is not below it.
---@param file string  absolute path
---@return string?
local function _cwd_relative(file)
    local cwd = vim.fs.normalize(vim.fn.getcwd())
    file = vim.fs.normalize(file)
    -- Relative to the root every path is "relative", and dropping the leading slash
    -- buys nothing but confusion.
    if cwd == "/" then return nil end
    -- Resolved as a second try: a symlinked cwd (as /tmp is on macOS) spells out
    -- differently than the same directory reached through the link, and the two
    -- would otherwise never look related.
    return vim.fs.relpath(cwd, file)
        or vim.fs.relpath(vim.fs.normalize(vim.fn.resolve(cwd)), vim.fs.normalize(vim.fn.resolve(file)))
end

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

--- Rewrite the path of every `@` reference in `line` through `fn`, which returns the
--- new path or nil to leave a reference as it is. Right to left, so the earlier
--- references' offsets still hold after a replacement.
---@param line string
---@param fn fun(ref: keystone.notes.Ref): string?
---@return string
local function _map_refs(line, fn)
    local refs = _refs(line)
    for i = #refs, 1, -1 do
        local ref = refs[i]
        local path = fn(ref)
        if path and path ~= ref.path then
            local lnum = ref.lnum and (":" .. ref.lnum) or ""
            -- `ref.start` is the `@` itself, which stays put.
            line = line:sub(1, ref.start) .. path .. lnum .. line:sub(ref.stop + 1)
        end
    end
    return line
end

--- A buffer line in the form the file stores: absolute paths, so the note points at
--- the same file from any cwd. A relative path naming nothing on disk is left as
--- typed -- `@param` in a note about a Lua annotation is text, not a path waiting to
--- be expanded.
---@param line string
---@return string
function M.to_stored(line)
    return _map_refs(line, function(ref)
        local anchored = vim.startswith(ref.path, "/") or vim.startswith(ref.path, "~")
        if not anchored and vim.fn.filereadable(ref.file) == 0
            and vim.fn.isdirectory(ref.file) == 0 then
            return nil
        end
        return ref.file
    end)
end

--- A stored line in the form the buffer shows: paths in or below the cwd shortened
--- to cwd-relative, the rest left as they are.
---@param line string
---@return string
function M.to_display(line)
    return _map_refs(line, function(ref)
        return _cwd_relative(ref.file)
    end)
end

--- Parse one stored line into a note. Every non-blank line is a valid note: an `@`
--- reference anchors it, and its absence simply means the note has no location.
--- Only a blank line is rejected.
---@param line string
---@return keystone.notes.Note?
function M.decode_line(line)
    local text = line:match("^%s*(.-)%s*$")
    if text == "" then return nil end

    -- The first reference anchors the note; any others are simply part of its text.
    local ref = _refs(text)[1]
    if not ref then
        return { label = text }
    end
    return { label = text, file = ref.file, lnum = ref.lnum }
end

--- The notes as they stand. A live notes buffer is the working copy and may hold
--- edits not yet written out, so it is read in preference to the file.
---@return keystone.notes.Note[]
function M.read_notes()
    local bufnr = M.live_bufnr()
    local lines = bufnr and vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) or M.read_lines()

    local notes = {}
    for _, line in ipairs(lines) do
        local note = M.decode_line(line)
        if note then notes[#notes + 1] = note end
    end
    return notes
end

--- The notes file's lines, or none when it does not exist yet.
---@return string[]
function M.read_lines()
    local ok, raw = fsutil.read_content(M.store_filepath())
    if not ok or raw == "" then return {} end
    return vim.split((raw:gsub("\r?\n$", "")), "\r?\n")
end

--- The file's lines, or nil when there is no file at all. Only the second case is
--- worth distinguishing from an empty one: another instance emptying the notes is a
--- change to merge, while the file having gone missing is not -- treating that as
--- "every note was deleted" would wipe a buffer full of notes.
---@return string[]?
local function _read_theirs()
    if not vim.uv.fs_stat(M.store_filepath()) then return nil end
    return M.read_lines()
end

--- Write `lines` to the notes file. Written beside it and renamed into place, so an
--- instance reading while another writes sees the old file or the new one, never half
--- of either.
---@param lines string[]
---@return boolean ok
local function _write_file(lines)
    local path = M.store_filepath()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

    local tmp = path .. ".tmp." .. vim.fn.getpid()
    if vim.fn.writefile(lines, tmp) ~= 0 then
        vim.notify("[keystone] Cannot write notes file: " .. path, vim.log.levels.ERROR)
        return false
    end
    local ok, err = vim.uv.fs_rename(tmp, path)
    if not ok then
        vim.fn.delete(tmp)
        vim.notify("[keystone] Cannot replace notes file: " .. tostring(err), vim.log.levels.ERROR)
        return false
    end
    return true
end

---@param lines string[]
---@return table<string, integer>
local function _counts(lines)
    local counts = {}
    for _, line in ipairs(lines) do counts[line] = (counts[line] or 0) + 1 end
    return counts
end

--- Three-way merge of note lines, so two Neovim instances editing the same notes file
--- keep each other's work. Lines are matched by their exact text and counted, not
--- positioned: notes are an unordered list, and an edited note reads as one line
--- deleted and another added, which is the right answer for free text.
---@param base string[]    the file as it stood when this buffer was filled
---@param mine string[]    the buffer now
---@param theirs string[]  the file now, another instance having written it
---@return string[]
local function _merge_lines(base, mine, theirs)
    -- Base lines this buffer still accounts for. What is left over once `mine` has
    -- been walked is what this buffer deleted, which doubles as the budget for
    -- dropping lines from `theirs`.
    local credit = _counts(base)

    local added = {}
    for _, line in ipairs(mine) do
        local left = credit[line] or 0
        if left > 0 then
            credit[line] = left - 1
        else
            added[#added + 1] = line
        end
    end

    local merged = {}
    for _, line in ipairs(theirs) do
        local deleted = credit[line] or 0
        if deleted > 0 then
            credit[line] = deleted - 1
        else
            merged[#merged + 1] = line
        end
    end
    return vim.list_extend(merged, added)
end

M.merge_lines = _merge_lines

-- The buffer the notes are edited in. Deliberately not a buffer editing the notes
-- file: as a scratch buffer nothing about the file is Vim's business -- no swap file
-- to go stale, no write hooks meant for real files, no unsaved-changes prompt on
-- quit. Its lines are the working copy, written back by `save_buffer`.
local _bufnr = nil

-- The file as it stood when the buffer was last filled or written -- the common
-- ancestor the merge works from, in stored form.
---@type string[]
local _base = {}

-- 'modified' is meaningless on a `nofile` buffer -- Vim keeps it off and refuses to
-- have it set -- so unsaved edits are spotted by comparing the buffer's changedtick
-- against the tick it last held when written out.
---@param bufnr integer
local function _mark_saved(bufnr)
    vim.b[bufnr].keystone_notes_tick = vim.api.nvim_buf_get_changedtick(bufnr)
end

---@param bufnr integer
---@return boolean
local function _is_dirty(bufnr)
    return vim.b[bufnr].keystone_notes_tick ~= vim.api.nvim_buf_get_changedtick(bufnr)
end

--- The notes buffer, created and filled from the file the first time it is asked for.
---@return integer
function M.get_buffer()
    if _bufnr and vim.api.nvim_buf_is_valid(_bufnr) then return _bufnr end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, "keystone://notes")
    _base = M.read_lines()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.tbl_map(M.to_display, _base))
    _mark_saved(bufnr)
    _bufnr = bufnr
    return bufnr
end

--- The notes buffer, only if one is live -- callers that must not create it.
---@return integer?
local function _live_bufnr()
    if _bufnr and vim.api.nvim_buf_is_valid(_bufnr) then return _bufnr end
    return nil
end

M.live_bufnr = _live_bufnr

--- The buffer's lines in the form the file stores them.
---@param bufnr integer
---@return string[]
local function _stored_lines(bufnr)
    return vim.tbl_map(M.to_stored, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
end

--- Replace the buffer's contents with `lines`, given in stored form.
---@param bufnr integer
---@param lines string[]
local function _show(bufnr, lines)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.tbl_map(M.to_display, lines))
end

--- Take in whatever another instance has written to the notes file since this buffer
--- was filled, keeping this buffer's own unsaved edits. Writes nothing.
---@param bufnr integer?
function M.sync_buffer(bufnr)
    bufnr = bufnr or _live_bufnr()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

    local theirs = _read_theirs()
    if not theirs or vim.deep_equal(theirs, _base) then return end

    local dirty = _is_dirty(bufnr)
    local mine = _stored_lines(bufnr)
    local merged = _merge_lines(_base, mine, theirs)
    -- The file is what it is, whatever this buffer still holds unsaved on top.
    _base = theirs
    if vim.deep_equal(merged, mine) then return end

    _show(bufnr, merged)
    if not dirty then _mark_saved(bufnr) end
end

--- Write the buffer's lines to the notes file, if it has unsaved changes, with their
--- paths back in stored form. Defaults to the notes buffer, which is what the
--- autocmds pass.
---
--- Another instance may have written the file since this buffer was filled; its notes
--- are merged in rather than overwritten, and the result shown here as well as
--- written. With nothing of our own to write there is still the other instance's work
--- to pick up, which is `sync_buffer`'s job.
---@param bufnr integer?
function M.save_buffer(bufnr)
    bufnr = bufnr or _live_bufnr()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not _is_dirty(bufnr) then
        M.sync_buffer(bufnr)
        return
    end

    local mine = _stored_lines(bufnr)
    local theirs = _read_theirs()
    local lines = mine
    if theirs and not vim.deep_equal(theirs, _base) then
        lines = _merge_lines(_base, mine, theirs)
    end

    if not _write_file(lines) then return end
    _base = lines
    if not vim.deep_equal(lines, mine) then _show(bufnr, lines) end
    _mark_saved(bufnr)
end

-- `:e` on the notes buffer would empty it: Vim frees the lines and, a scratch buffer
-- having no file behind it, finds nothing to read back. The working copy is set aside
-- as the buffer unloads and put back when it is read, so a reload -- however it was
-- asked for -- leaves the notes, unsaved edits included, as they were.
---@type string[]?
local _unloaded = nil
local _unloaded_dirty = false

--- Keep the buffer's lines over an unload.
---@param bufnr integer?
function M.stash_buffer(bufnr)
    bufnr = bufnr or _live_bufnr()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
    _unloaded = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    _unloaded_dirty = _is_dirty(bufnr)
end

--- Put the stashed lines back, if the buffer was unloaded rather than filled fresh.
--- Restoring is not an edit: the buffer is as dirty afterwards as it was before.
---@param bufnr integer?
function M.restore_buffer(bufnr)
    bufnr = bufnr or _live_bufnr()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not _unloaded then return end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, _unloaded)
    _unloaded = nil
    if not _unloaded_dirty then _mark_saved(bufnr) end
end

-- The buffer's lines in stored form, taken while the cwd they are shown against is
-- still current: a relative path means nothing once the cwd has moved, so
-- `refresh_display` cannot work them out for itself after the fact.
---@type string[]?
local _pending_stored = nil

--- Canonicalize the shown lines ahead of a cwd change, for `refresh_display` to
--- re-render afterwards.
---@param bufnr integer?
function M.snapshot_lines(bufnr)
    bufnr = bufnr or _live_bufnr()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
    _pending_stored = vim.tbl_map(M.to_stored, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
end

--- Re-render the buffer's paths for the current cwd -- what a `:cd` calls for, since
--- which paths shorten depends on where the cwd now is. Unsaved edits are kept (and
--- stay unsaved): the lines make the round trip through stored form, which is what
--- they would have been written as anyway.
---@param bufnr integer?
function M.refresh_display(bufnr)
    bufnr = bufnr or _live_bufnr()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

    local dirty = _is_dirty(bufnr)
    local shown = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local stored = _pending_stored or vim.tbl_map(M.to_stored, shown)
    _pending_stored = nil

    local redrawn = vim.tbl_map(M.to_display, stored)
    if vim.deep_equal(shown, redrawn) then return end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, redrawn)
    -- Re-rendering is not an edit: only the user's own changes make it dirty.
    if not dirty then _mark_saved(bufnr) end
end

--- Append `text`, a line in stored form, as a new line. A live notes buffer takes the
--- line -- shown its own way -- instead of the file, so the two never diverge, and is
--- written out straight away.
---@param text string
local function _append_line(text)
    local path = M.store_filepath()

    local bufnr = _live_bufnr()
    if bufnr then
        local last = vim.api.nvim_buf_get_lines(bufnr, -2, -1, false)[1]
        -- An empty buffer is one empty line; overwrite it rather than leaving a gap.
        local from = (last == nil or last == "") and -2 or -1
        vim.api.nvim_buf_set_lines(bufnr, from, -1, false, { M.to_display(text) })
        M.save_buffer(bufnr)
        return
    end

    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

    -- A file not ending in a newline would otherwise swallow the new note into its
    -- last line, so check the final byte before appending.
    local needs_nl = false
    local r = io.open(path, "r")
    if r then
        if r:seek("end") > 0 then
            r:seek("end", -1)
            needs_nl = r:read(1) ~= "\n"
        end
        r:close()
    end

    local f = io.open(path, "a")
    if not f then
        vim.notify("[keystone] Cannot write notes file: " .. path, vim.log.levels.ERROR)
        return
    end
    f:write((needs_nl and "\n" or "") .. text .. "\n")
    f:close()
end

M.append_line = _append_line

---@param file string?
---@return string?
function M.norm(file)
    if not file or file == "" then return file end
    return vim.fn.fnamemodify(file, ":p")
end

--- Append a note reading `text` behind a reference to `file`(`:lnum`) -- the shape
--- `:Notes add` produces, where the location comes from the cursor rather than from
--- anything the user typed. The reference leads, so the list reads as locations first
--- with the note text following.
---@param text string
---@param file string?
---@param lnum integer?
function M.add_at(text, file, lnum)
    if not file then
        _append_line(text)
        return
    end
    -- Stored form: the absolute path. `_append_line` shortens it for the buffer.
    local ref = "@" .. vim.fs.normalize(M.norm(file) --[[@as string]])
    if lnum then ref = ref .. ":" .. lnum end
    _append_line(text ~= "" and (ref .. " " .. text) or ref)
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
    -- Use the buffer name (not expand("%:p")): on symlinked paths the two disagree,
    -- and a note's file has to be keyed the one way throughout.
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file == "" then
        return
    end
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    return file, lnum
end

---@param config keystone.notes.Config
function M.init(config)
    _config = config
end

return M
