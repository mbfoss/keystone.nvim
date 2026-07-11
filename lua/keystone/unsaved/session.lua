local M          = {}

local fsutil     = require("keystone.tk.fsutil")

--- Quickfix-driven diff of every modified buffer's unsaved (in-memory) state
--- against its saved (on-disk) state. Modelled on Neovim's built-in difftool
--- (`runtime/pack/dist/opt/nvim.difftool`): the quickfix list indexes the
--- changed files, and navigating it drives a side-by-side native diff.
--- Unlike the built-in, which compares two paths on disk, the live side is the
--- real (unsaved) buffer and the saved side is a scratch buffer of the on-disk
--- text. The whole thing runs in its own tab page so the user's layout is
--- preserved.

--- Status letter -> highlight group, matching the built-in difftool's quickfix
--- colouring. Only "M" and "A" arise here (modified buffers and new buffers

--- Active session state. Only one session exists at a time. The session drives
--- the global quickfix list.
---@class keystone.unsaved.Layout
---@field group     integer?  augroup id, nil when no session is active
---@field tab       integer?  tabpage handle the diff lives in
---@field left_win  integer?  window for the saved (on-disk) side
---@field right_win integer?  window for the live (unsaved buffer) side
local _layout    = { group = nil, tab = nil, left_win = nil, right_win = nil }

--- Plugin-unique key stamped into each quickfix entry's `user_data`. Its
--- presence is how a session recognises its own entries; nesting our data under
--- it (rather than a generic flag like the built-in difftool's `diff = true`)
--- guarantees no clash with another plugin's `user_data`.
local _ENTRY_KEY = "keystone.unsaved"

--- setqflist `title`, used both to populate the list and to recognise (in the
--- QuickFixCmdPost guard below) whether the quickfix list is still ours or has
--- been overwritten by an unrelated :vimgrep/:caddexpr.
local _QFLIST_TITLE = "DiffUnsaved: modified buffers"

--- The per-entry payload stored under `user_data[_ENTRY_KEY]`.
---@class keystone.unsaved.EntryData
---@field bufnr integer
---@field path  string
---@field rel   string

--- Guards _cleanup against the re-entrancy from closing our own windows/tab.
local _closing   = false

--- Tear down the active session: drop the autocmds and close the quickfix
--- window. Windows/tab are left for the user (or already gone); idempotent.
local function _cleanup()
    if _closing then return end
    _closing = true

    if _layout.group then
        vim.api.nvim_del_augroup_by_id(_layout.group)
        _layout.group = nil
    end

    -- Close the quickfix window via its winid so this works regardless of
    -- which window currently has focus.
    local qwin = vim.fn.getqflist({ winid = 1 }).winid
    if qwin ~= 0 and vim.api.nvim_win_is_valid(qwin) then
        vim.api.nvim_win_close(qwin, false)
    end

    if _layout.left_win then
        if vim.api.nvim_win_is_valid(_layout.left_win) then
            vim.api.nvim_win_close(_layout.left_win, false)
        end
        _layout.left_win = nil
    end

    if _layout.right_win then
        if vim.api.nvim_win_is_valid(_layout.right_win) then
            vim.api.nvim_win_close(_layout.right_win, false)
        end
        _layout.right_win = nil
    end

    _layout.tab = nil
    _closing    = false
end

--- Collect every loaded, file-backed, modified buffer as a quickfix entry.
---@return table[] entries
local function _collect_entries()
    local cwd     = vim.fn.getcwd()
    local entries = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr)
            and vim.bo[bufnr].modified
            and vim.bo[bufnr].buftype == "" then
            local name = vim.api.nvim_buf_get_name(bufnr)
            if name ~= "" then
                local path            = vim.fn.fnamemodify(name, ":p")
                local rel             = fsutil.get_relative_path(path, cwd)
                    or vim.fn.fnamemodify(path, ":~:.")
                local status          = vim.fn.filereadable(path) == 1 and "M" or "A"
                entries[#entries + 1] = {
                    bufnr     = bufnr,
                    filename  = path,
                    text      = status,
                    ---@type table<string, keystone.unsaved.EntryData>
                    user_data = { [_ENTRY_KEY] = { bufnr = bufnr, path = path, rel = rel } },
                }
            end
        end
    end
    table.sort(entries, function(a, b)
        return a.user_data[_ENTRY_KEY].rel < b.user_data[_ENTRY_KEY].rel
    end)
    return entries
end

--- Scratch buffer holding the on-disk contents for the saved side of the diff.
--- Read-only and wiped when it leaves its window.
---@param ud {bufnr:integer, path:string, rel:string}
---@return integer bufnr
local function _make_saved_buf(ud)
    local buf   = vim.api.nvim_create_buf(false, true)
    local lines = {}
    if vim.fn.filereadable(ud.path) == 1 then
        lines = vim.fn.readfile(ud.path)
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    vim.bo[buf].buftype   = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile  = false
    if vim.api.nvim_buf_is_valid(ud.bufnr) then
        vim.bo[buf].filetype = vim.bo[ud.bufnr].filetype
    end
    vim.bo[buf].modifiable = false
    -- The buffer id keeps the name unique, so the saved scratch for a file can
    -- never clash with a not-yet-wiped predecessor (rapid re-navigation).
    vim.api.nvim_buf_set_name(buf, ("unsaved://saved/%d/%s"):format(buf, ud.rel))
    return buf
end

--- The current entry of the session's quickfix list, but only if it is one of
--- ours (empty list or a foreign entry yields nil). With `bufnr`, additionally
--- require the entry to belong to that buffer.
---@param bufnr integer?
---@return table? entry
local function _current_diff_entry(bufnr)
    local rw = _layout.right_win
    if not (rw and vim.api.nvim_win_is_valid(rw)) then return nil end

    local info = vim.fn.getqflist({ idx = 0, items = 1, size = 1 })
    if info.size == 0 then return nil end

    local entry = info.items[info.idx]
    if not entry
        or not entry.user_data
        or not entry.user_data[_ENTRY_KEY]
        or (bufnr and entry.bufnr ~= bufnr) then
        return nil
    end
    return entry
end

--- Lay the live buffer (already in a diff window after quickfix navigation)
--- against a fresh saved-side scratch buffer, in native diff mode.
---@param entry table
local function _setup_diff(entry)
    local lw, rw = _layout.left_win, _layout.right_win
    if not (lw and vim.api.nvim_win_is_valid(lw)
            and rw and vim.api.nvim_win_is_valid(rw)) then
        return
    end

    local ud = entry.user_data[_ENTRY_KEY]

    -- The live buffer lands in whichever diff window the navigation reused;
    -- put the saved scratch in the other so the pair stays side by side.
    local live_win, saved_win
    if vim.api.nvim_win_get_buf(lw) == ud.bufnr then
        live_win, saved_win = lw, rw
    else
        live_win, saved_win = rw, lw
    end

    vim.api.nvim_win_set_buf(saved_win, _make_saved_buf(ud))

    -- Clear stale diff state in this tab, then diff the pair. Running from one
    -- of our windows scopes `diffoff!` to this tab regardless of focus.
    vim.api.nvim_win_call(live_win, function() vim.cmd("diffoff!") end)
    vim.api.nvim_win_call(saved_win, vim.cmd.diffthis)
    vim.api.nvim_win_call(live_win, vim.cmd.diffthis)
end

--- Open the two-pane diff layout in a fresh tab. The quickfix window is opened
--- later, once the list has been populated.
local function _build_layout()
    vim.cmd.tabnew()
    _layout.tab      = vim.api.nvim_get_current_tabpage()
    _layout.left_win = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vsplit")
    _layout.right_win = vim.api.nvim_get_current_win()

    for _, win in ipairs({ _layout.left_win, _layout.right_win }) do
        vim.api.nvim_create_autocmd("WinClosed", {
            group    = _layout.group,
            pattern  = tostring(win),
            callback = _cleanup,
        })
    end
    vim.api.nvim_create_autocmd("TabClosed", {
        group    = _layout.group,
        callback = function()
            if not (_layout.tab and vim.api.nvim_tabpage_is_valid(_layout.tab)) then
                _cleanup()
            end
        end,
    })
end

--- Register the two BufWinEnter handlers that drive the session: one colours
--- the quickfix status letters, the other builds the diff when the current
--- entry's live buffer is shown.
local function _register_autocmds()
    -- Quickfix navigation (`:cnext`, `<CR>`, ...) has no dedicated autocmd, so
    -- -- like the built-in difftool -- we hook the buffer that navigation lands
    -- in. Unlike the built-in's global `*` trigger, this only acts when the
    -- entry's buffer enters one of *our* diff windows, so opening that buffer
    -- elsewhere never rebuilds the session.
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group    = _layout.group,
        pattern  = "*",
        callback = function(ev)
            local win = vim.api.nvim_get_current_win()
            if win ~= _layout.left_win and win ~= _layout.right_win then return end
            local entry = _current_diff_entry(ev.buf)
            if not entry then return end
            vim.schedule(function() _setup_diff(entry) end)
        end,
    })

    -- Commands like :vimgrep, :grep, or :caddexpr silently replace the
    -- quickfix list (and drop our quickfixtextfunc), leaving the session's
    -- tab/windows open with no entries of ours left to navigate. Detect the
    -- takeover via the list title and tear the session down rather than let it
    -- linger in that broken state.
    vim.api.nvim_create_autocmd("QuickFixCmdPost", {
        group    = _layout.group,
        pattern  = "[^l]*",
        callback = function()
            if not (_layout.right_win and vim.api.nvim_win_is_valid(_layout.right_win)) then
                return
            end
            local info = vim.fn.getqflist({ title = 1 })
            if info.title ~= _QFLIST_TITLE then
                vim.schedule(_cleanup)
            end
        end,
    })
end

--- Open the diff of unsaved vs saved state for all modified buffers.
function M.open()
    -- Re-running starts clean.
    if _layout.group then _cleanup() end

    local entries = _collect_entries()
    if #entries == 0 then
        vim.notify("[keystone] No modified buffers to diff", vim.log.levels.INFO)
        return
    end

    _layout.group = vim.api.nvim_create_augroup("keystone.unsaved", { clear = true })
    _register_autocmds()
    _build_layout()

    -- The quickfix list is global; populate it after the layout exists so
    -- navigation has our diff windows to land in.
    vim.fn.setqflist({}, " ", {
        title            = _QFLIST_TITLE,
        items            = entries,
        ---@param info {id:integer, winid:integer, start_idx:integer, end_idx:integer}
        quickfixtextfunc = function(info)
            local items = vim.fn.getqflist({ id = info.id, items = 1 }).items
            local out   = {}
            for i = info.start_idx, info.end_idx do
                local e       = items[i]
                local ud      = e.user_data and e.user_data[_ENTRY_KEY]
                out[#out + 1] = (e.text or "?") .. " " .. ((ud and ud.rel) or e.filename or "")
            end
            return out
        end,
    })

    vim.cmd("botright copen")
    vim.api.nvim_set_current_win(_layout.right_win)
    vim.cmd.cfirst()
end

return M
