---@class keystone.notes.actions
local M        = {}

-- Interactive note commands. This module pulls in the heavy UI modules
-- (inputwin, ui, fixedwin) and is required only the first time a command runs,
-- keeping startup cheap. `keystone.notes` forwards to these on demand.

local core     = require("keystone.notes.core")
local inputwin = require("keystone.util.inputwin")
local ui       = require("keystone.util.ui")
local fixedwin = require("keystone.util.fixedwin")

-- Height ratio of the notes list split, tracked live by fixedwin and reused
-- so reopening the list keeps the height the user last dragged it to.
local _list_ratio = 0.25

--- `completefunc` for the notes buffer (triggered by typing `@`, or by hand with
--- <C-x><C-u>): completes the path inside the `@` reference under the cursor.
--- Scoped to the whole whitespace-delimited token, and only when that token opens
--- with `@`, so ordinary note text is never treated as a path.
--- `getcompletion(_, "file")` keeps the typed path form (cwd- or `~`-relative) and
--- marks directories with a trailing `/`.
---@param findstart 0|1
---@param base string
---@return integer|string[]
function M.complete_path(findstart, base)
    local line   = vim.api.nvim_get_current_line()
    local col    = vim.api.nvim_win_get_cursor(0)[2] -- 0-based cursor byte offset
    local before = line:sub(1, col)
    local token  = before:match("%S*$")

    if findstart == 1 then
        -- Not inside an `@` reference: cancel the completion, stay in insert.
        if not token:match("^@") then return -2 end
        return col - #token + 1 -- 0-based byte column just past the `@`
    end

    return vim.fn.getcompletion(base, "file")
end

--- Text before the cursor on the current line, in insert mode.
---@return string
local function _before_cursor()
    return vim.api.nvim_get_current_line():sub(1, vim.api.nvim_win_get_cursor(0)[2])
end

--- `@` in the notes buffer: insert it and open path completion straight away, but
--- only where a reference can actually start (line start or after whitespace) --
--- the same rule the parser applies, so typing an address like bob@example.com
--- neither completes nor is mistaken for a path.
---@return string
local function _at_key()
    local before = _before_cursor()
    if before == "" or before:match("%s$") then
        return "@<C-x><C-u>"
    end
    return "@"
end

--- Prompt for the note text and append it. `file`/`lnum` anchor the note when
--- given. The prompt names which kind is being written: the window opens at the
--- cursor either way, so the title is the only thing distinguishing an unanchored
--- note from an anchored one.
---@param file string?
---@param lnum integer?
local function _prompt_note(file, lnum)
    local prompt = file and "Note" or "Note (no location)"
    inputwin.open({ prompt = prompt, default = "" }, function(label)
        if not label then return end
        label = label:match("^%s*(.-)%s*$")
        if label == "" then return end
        core.add_at(label, file, lnum)
    end)
end

function M.add_at_cursor()
    local file, lnum = core.get_cur_loc()
    if not file or not lnum then
        vim.notify("[keystone] No valid file at cursor", vim.log.levels.WARN)
        return
    end
    _prompt_note(core.norm(file), lnum)
end

function M.add_free()
    _prompt_note(nil, nil)
end

--- Pick the `@` references out of the note text with a syntax rule: it re-matches
--- as the user types, so highlighting never has to be recomputed by hand.
--- `\%(^\|\s\)\@<=` keeps it to a token start, matching the parse, so
--- bob@example.com stays plain text.
---@param bufnr integer
local function _apply_syntax(bufnr)
    vim.api.nvim_buf_call(bufnr, function()
        vim.cmd([[syntax clear]])
        vim.cmd([[syntax match KeystoneNoteRef /\%(^\|\s\)\@<=@\S\+/]])
    end)
end

--- Opens the notes in a split. The buffer is a scratch buffer, not a buffer editing
--- the notes file: edit it freely and its lines are written to the file whenever it
--- stops being current and on exit; delete a note by deleting its line. Each line is
--- free text, optionally carrying an `@<path>[:<lnum>]` reference anywhere in it;
--- <C-x><C-u> completes the path inside such a reference.
function M.open_list()
    local bufnr = core.get_buffer()

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

    -- The buffer outlives the window, so its note-editing setup is done once.
    if vim.b[bufnr].keystone_notes then return end
    vim.b[bufnr].keystone_notes = true

    vim.bo[bufnr].completefunc = "v:lua.require'keystone.notes.actions'.complete_path"

    -- Typing `@` is the trigger: a reference is the one thing in a note with a
    -- fixed vocabulary, so there is no reason to make the user ask for the list.
    -- <C-x><C-u> still works by hand.
    vim.keymap.set("i", "@", _at_key,
        { buffer = bufnr, expr = true, desc = "Start a path reference" })

    -- <CR> follows the reference *under the cursor*, so a note mentioning several
    -- files opens the one being pointed at rather than whichever comes first.
    -- Off any reference there is nothing to open, and nothing happens.
    vim.keymap.set("n", "<CR>", function()
        local line = vim.api.nvim_get_current_line()
        local col = vim.api.nvim_win_get_cursor(0)[2] + 1 -- 1-based byte column
        local ref = core.ref_at(line, col)
        if not ref then return end
        -- A reference naming only a file opens it at the top.
        ui.smart_open_file(ref.file, ref.lnum or 1, 0)
    end, { buffer = bufnr, desc = "Open the reference under the cursor" })

    -- The buffer is the working copy for the whole session, written out whenever it
    -- stops being current.
    vim.api.nvim_create_autocmd("BufLeave", {
        buffer   = bufnr,
        callback = function() core.save_buffer(bufnr) end,
    })

    -- Another Neovim instance may have written the file in the meantime; its notes are
    -- merged in on the way back to the list rather than waiting for the next write.
    vim.api.nvim_create_autocmd("BufEnter", {
        buffer   = bufnr,
        callback = function() core.sync_buffer(bufnr) end,
    })

    -- Neither event is buffer-local, hence the group: a notes buffer replacing a wiped
    -- one re-registers rather than stacking up.
    local group = vim.api.nvim_create_augroup("KeystoneNotes", { clear = true })

    -- Quitting with the notes window current never leaves the buffer, so BufLeave
    -- alone would lose the last edits.
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group    = group,
        callback = function() core.save_buffer(bufnr) end,
    })

    -- Coming back to this instance is the moment another one's notes are worth
    -- picking up, even with the list sitting there untouched.
    vim.api.nvim_create_autocmd("FocusGained", {
        group    = group,
        callback = function() core.sync_buffer(bufnr) end,
    })

    -- Paths are shown relative to the cwd, so a `:cd` changes which of them shorten
    -- and how far. The shown lines have to be canonicalized before the move, while the
    -- cwd they were rendered against still says what they point at.
    vim.api.nvim_create_autocmd("DirChangedPre", {
        group    = group,
        callback = function() core.snapshot_lines(bufnr) end,
    })
    vim.api.nvim_create_autocmd("DirChanged", {
        group    = group,
        callback = function() core.refresh_display(bufnr) end,
    })

    vim.api.nvim_set_hl(0, "KeystoneNoteRef", { link = "Directory", default = true })
    _apply_syntax(bufnr)
end

return M
