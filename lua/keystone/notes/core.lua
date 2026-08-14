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
--     off-by-one in @~/src/parser.lua:19 -- check the bounds
--     the whole tokenizer needs a rewrite: @~/src/lexer.lua
--     ask the team about cache invalidation
--
-- The reference is `@<path>` with an optional `:<lnum>`, and must start a token
-- (preceded by whitespace or the line start) so an address like bob@example.com
-- is left alone. The first reference in the line wins; everything else, `@` or
-- not, is just text.
--
-- Nothing is kept in memory and nothing is rewritten: `:Notes add` appends a line,
-- `:Notes list` edits the file. Deleting a note is deleting its line.

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

---@return keystone.notes.Note[]
function M.read_notes()
    local ok, raw = fsutil.read_content(M.store_filepath())
    if not ok or raw == "" then return {} end

    local notes = {}
    for line in raw:gmatch("[^\r\n]+") do
        local note = M.decode_line(line)
        if note then notes[#notes + 1] = note end
    end
    return notes
end

---@param path string
---@return integer?  a loaded buffer editing `path`, if there is one
local function _live_bufnr(path)
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then return bufnr end
    return nil
end

--- Append `text` as a new line. A buffer already editing the notes file takes the
--- line instead of the file, so the two never diverge; writing it stays the user's
--- call, exactly as with any other edit to that buffer.
---@param text string
local function _append_line(text)
    local path = M.store_filepath()

    local bufnr = _live_bufnr(path)
    if bufnr then
        local last = vim.api.nvim_buf_get_lines(bufnr, -2, -1, false)[1]
        -- An empty buffer is one empty line; overwrite it rather than leaving a gap.
        local from = (last == nil or last == "") and -2 or -1
        vim.api.nvim_buf_set_lines(bufnr, from, -1, false, { text })
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

--- Append a note reading `text` with a reference to `file`(`:lnum`) after it -- the
--- shape `:Notes add` produces, where the location comes from the cursor rather than
--- from anything the user typed.
---@param text string
---@param file string?
---@param lnum integer?
function M.add_at(text, file, lnum)
    if not file then
        _append_line(text)
        return
    end
    local ref = "@" .. _encode_path(M.norm(file) --[[@as string]])
    if lnum then ref = ref .. ":" .. lnum end
    _append_line(text ~= "" and (text .. " " .. ref) or ref)
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
