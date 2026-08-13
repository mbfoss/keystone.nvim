---@class keystone.notes.actions
local M           = {}

-- Interactive note commands. This module pulls in the heavy UI modules
-- (inputwin, ui, fixedwin) and is required only the first time a command runs,
-- keeping startup cheap. `keystone.notes` forwards to these on demand.

local core     = require("keystone.notes.core")
local throttle = require("keystone.util.throttle")
local inputwin = require("keystone.util.inputwin")
local ui       = require("keystone.util.ui")
local fixedwin = require("keystone.util.fixedwin")

-- Height ratio of the notes list split, tracked live by fixedwin and reused
-- so reopening the list keeps the height the user last dragged it to.
local _list_ratio = 0.25

--- `completefunc` for the notes list buffer (triggered with <C-x><C-u>): completes
--- the file path in the optional location field. Scoped to the path token -- bytes
--- up to the cursor that are neither whitespace nor the `:` that introduces the line
--- number -- and only when the ` -- ` separator immediately precedes it, so the note
--- text before it and the `:lnum` after it are never treated as a path.
--- `getcompletion(_, "file")` keeps the stored path form (cwd- or `~`-relative) and
--- marks directories with a trailing `/`.
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
        -- Not in the location field (or nothing to complete): cancel, stay in insert.
        if token == "" or not before:sub(1, start):match("%s%-%-%s*$") then return -2 end
        return start -- 0-based byte column where the path token begins
    end

    return vim.fn.getcompletion(base, "file")
end

--- Prompt for the note text and store it. `file`/`lnum` anchor the note when given;
--- `replace` is the note being rewritten, whose text seeds the prompt. The prompt
--- names which kind is being written: the window opens at the cursor either way, so
--- the title is the only thing distinguishing an unanchored note from an anchored one.
---@param file string?
---@param lnum integer?
---@param default string?
---@param replace keystone.notes.Note?
local function _prompt_note(file, lnum, default, replace)
    local prompt = file and "Note" or "Note (no location)"
    inputwin.open({ prompt = prompt, default = default or "" }, function(label)
        if not label then return end
        label = label:match("^%s*(.-)%s*$")
        if label == "" then return end
        if replace then core.remove(replace.id) end
        core.add(label, file, lnum)
        core.refresh_list()
    end)
end

function M.add_at_cursor()
    local file, lnum = core.get_cur_loc()
    if not file or not lnum then
        vim.notify("[keystone] No valid file at cursor", vim.log.levels.WARN)
        return
    end
    local path = core.norm(file) --[[@as string]]

    -- A line already carrying a note re-opens that note for editing rather than
    -- stacking a second one on the same spot; a new note starts from an empty prompt.
    local existing = core.note_at(path, lnum)
    _prompt_note(path, lnum, existing and existing.label or nil, existing)
end

function M.add_free()
    _prompt_note(nil, nil, nil, nil)
end

function M.clear_file()
    local buf = vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local file = core.norm(vim.api.nvim_buf_get_name(buf))
    if not file or file == "" then return end
    ui.confirm_action("Clear notes in current file", false, function(accepted)
        if not accepted then return end
        core.remove_file(file)
        core.refresh_list()
    end)
end

function M.clear_all()
    if core.count() == 0 then
        return
    end
    ui.confirm_action("Clear all notes", false, function(accepted)
        if not accepted then return end
        core.remove_all()
        core.refresh_list()
    end)
end

-- Scratch buffer holding the on-disk preview of the highlighted note's file. Its
-- default 'bufhidden' wipes it as soon as another buffer takes over the preview
-- window, so it is recreated on demand and never outlives the picker.
local _preview_bufnr = nil

-- How much of an anchored file is read for the preview. The window shows a
-- screenful; the rest only matters for a note near the top of a big file.
local _PREVIEW_LINES = 500

--- Buffer to preview `note` in, for `vim.ui.select` implementations that support
--- `preview_item` (`keystone.select` does). Unanchored notes have nothing to show.
--- A file already open in Neovim is previewed through its own buffer, so unsaved
--- edits show; anything else is read from disk into a scratch buffer rather than
--- loaded as a real buffer -- loading would fire the whole autocmd chain and prompt
--- on a stale swap file.
---@param note keystone.notes.Note
---@return keystone.select.Preview?
local function _preview_note(note)
    if not (note.file and note.lnum) then return nil end

    local open = vim.fn.bufnr("^" .. note.file .. "$")
    if open ~= -1 and vim.api.nvim_buf_is_loaded(open) then
        return { buf = open, pos = { note.lnum, 0 } }
    end

    local stat = vim.uv.fs_stat(note.file)
    if not stat or stat.type ~= "file" then return nil end

    if not (_preview_bufnr and vim.api.nvim_buf_is_valid(_preview_bufnr)) then
        _preview_bufnr = ui.create_scratch_buffer(false, {})
    end
    vim.api.nvim_buf_set_lines(_preview_bufnr, 0, -1, false,
        vim.fn.readfile(note.file, "", _PREVIEW_LINES))
    -- 'syntax', not 'filetype': no FileType autocmd fires, so treesitter and the
    -- LSP never attach to what is only a preview.
    vim.bo[_preview_bufnr].syntax = vim.filetype.match({ filename = note.file }) or ""

    return { buf = _preview_bufnr, pos = { note.lnum, 0 } }
end

--- The notes as a picker: fuzzy over the note text *and* its location, with the
--- anchored line shown in the preview.
function M.pick()
    local notes = core.sorted_notes()
    if #notes == 0 then
        vim.notify("[keystone] No notes set", vim.log.levels.WARN)
        return
    end

    ---@type keystone.select.Opts
    local opts = {
        prompt       = "Notes",
        ---@param note keystone.notes.Note
        format_item  = function(note)
            if not (note.file and note.lnum) then return note.label end
            return note.label .. "  " .. vim.fn.fnamemodify(note.file, ":~:.") .. ":" .. note.lnum
        end,
        preview_item = _preview_note,
    }

    vim.ui.select(notes, opts, function(note)
        if note and note.file and note.lnum then
            ui.smart_open_file(note.file, note.lnum, 0)
        end
    end)
end

--- Opens the notes list for editing in a split. The list is a scratch buffer
--- rendered from the in-memory notes -- not the file on disk. Edit lines freely;
--- edits synchronise automatically (throttled), updating the notes and their signs
--- in memory (see core.sync_from_buffer) without touching disk -- the file is saved
--- on exit. `:w` is unnecessary (and a no-op). Each line is `<note>[ -- <path>:<lnum>]`;
--- <C-x><C-u> completes the file path in the location field.
function M.open_list()
    -- Reuse the scratch buffer across opens so its content (kept in step with the
    -- notes by core.refresh_list) survives being hidden.
    local bufnr = core.list_bufnr
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
        bufnr = ui.create_scratch_buffer(true, {}, function()
            bufnr = nil
            core.list_bufnr = nil
        end)
        core.list_bufnr = bufnr

        -- `acwrite`, not `nofile`: keeps the no-disk-backing scratch semantics but
        -- gives the buffer a name, so `:w` is a clean no-op instead of E32. Syncing
        -- doesn't depend on `:w` -- edits flow to the notes (throttled TextChanged).
        local name = "keystone://notes"
        local existing = vim.fn.bufnr(name)
        if existing ~= -1 and existing ~= bufnr then
            vim.api.nvim_buf_delete(existing, { force = false })
        end
        vim.api.nvim_buf_set_name(bufnr, name)
        vim.bo[bufnr].buftype = "acwrite"
        vim.bo[bufnr].bufhidden = "hide"
        vim.bo[bufnr].swapfile = false

        -- custom completion function
        vim.bo[bufnr].completefunc = "v:lua.require'keystone.notes.actions'.complete_path"

        -- Push edited lines back into the notes as the user edits, throttled so a
        -- burst rebuilds the set at most once per window. Only syncs (no refresh_list):
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

        -- Edits flow into the notes live and the buffer never needs writing, so keep
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

        -- <CR> jumps to the note's location, when it has one, via the shared opener.
        vim.keymap.set("n", "<CR>", function()
            local line = vim.api.nvim_get_current_line()
            local note = core.decode_line(line)
            if not (note and note.file and note.lnum) then return end
            ui.smart_open_file(note.file, note.lnum, 0)
        end, { buffer = bufnr, desc = "Open the location of the note under cursor" })
    end

    -- Render current notes into the buffer before showing it.
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
