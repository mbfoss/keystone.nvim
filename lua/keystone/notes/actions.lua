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

--- `completefunc` for the notes list buffer (triggered by typing `@`, or by hand
--- with <C-x><C-u>): completes the path inside the `@` reference under the cursor.
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

--- `@` in the list buffer: insert it and open path completion straight away, but
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
        core.add_at(label, file, lnum)
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
    -- The prompt shows the note *without* its `@` reference, since confirming appends
    -- a fresh one for the cursor -- seeding it with the rendered text would double it.
    local existing = core.note_at(path, lnum)
    local default
    if existing then
        default = (existing.prefix .. existing.suffix):match("^%s*(.-)%s*$")
    end
    _prompt_note(path, lnum, default, existing)
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

--- Opens the notes list for editing in a split. The list is a scratch buffer
--- rendered from the in-memory notes -- not the file on disk. Edit lines freely;
--- edits synchronise automatically (throttled), updating the notes and their anchors
--- in memory (see core.sync_from_buffer) without touching disk -- the file is saved
--- on exit. `:w` is unnecessary (and a no-op). Each line is free text, optionally
--- carrying an `@<path>[:<lnum>]` reference anywhere in it; <C-x><C-u> completes the
--- path inside such a reference.
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

        -- Typing `@` is the trigger: a reference is the one thing in a note with a
        -- fixed vocabulary, so there is no reason to make the user ask for the list.
        -- <C-x><C-u> still works by hand.
        vim.keymap.set("i", "@", _at_key,
            { buffer = bufnr, expr = true, desc = "Start a path reference" })

        -- Pick the `@` references out of the note text with a syntax rule: it
        -- re-matches as the user types, so highlighting never lags the throttled
        -- sync or has to be recomputed by hand. `\%(^\|\s\)\@<=` keeps it to a token
        -- start, matching the parse, so bob@example.com stays plain text.
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd([[syntax clear]])
            vim.cmd([[syntax match KeystoneNoteRef /\%(^\|\s\)\@<=@\S\+/]])
        end)
        vim.api.nvim_set_hl(0, "KeystoneNoteRef", { link = "Directory", default = true })

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
