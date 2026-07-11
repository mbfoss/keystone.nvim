local M           = {}

local fsutil      = require("keystone.tk.fsutil")
local pick_select = require("keystone.pick.select")

--- Picker-driven diff of a modified buffer's unsaved (in-memory) state against
--- its saved (on-disk) state. Running the entry point lists every modified
--- buffer in a picker; choosing one opens a side-by-side native diff in its own
--- tab -- the live (unsaved) buffer on the right, a read-only scratch of the
--- on-disk text on the left -- so the user's layout is preserved. Unlike a
--- difftool-style list, the quickfix and location lists are never touched.

--- Active session state. Only one session exists at a time.
---@class keystone.unsaved.Layout
---@field group     integer?  augroup id, nil when no session is active
---@field tab       integer?  tabpage handle the diff lives in
---@field left_win  integer?  window for the saved (on-disk) side
---@field right_win integer?  window for the live (unsaved buffer) side
local _layout     = { group = nil, tab = nil, left_win = nil, right_win = nil }

--- One modified buffer, as offered in the picker and diffed on selection.
---@class keystone.unsaved.Entry
---@field bufnr  integer
---@field path   string
---@field rel    string
---@field status string  "M" when the file exists on disk, "A" when it is new

--- Guards _cleanup against the re-entrancy from closing our own windows/tab.
local _closing    = false

--- Tear down the active session: drop the autocmds and close the diff windows.
--- The tab collapses once its last window is gone; idempotent.
local function _cleanup()
    if _closing then return end
    _closing = true

    if _layout.group then
        vim.api.nvim_del_augroup_by_id(_layout.group)
        _layout.group = nil
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

--- Collect every loaded, file-backed, modified buffer, sorted by display path.
---@return keystone.unsaved.Entry[] entries
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
                entries[#entries + 1] = { bufnr = bufnr, path = path, rel = rel, status = status }
            end
        end
    end
    table.sort(entries, function(a, b) return a.rel < b.rel end)
    return entries
end

--- Scratch buffer holding the on-disk contents for the saved side of the diff.
--- Read-only and wiped when it leaves its window.
---@param entry keystone.unsaved.Entry
---@return integer bufnr
local function _make_saved_buf(entry)
    local buf   = vim.api.nvim_create_buf(false, true)
    local lines = {}
    if vim.fn.filereadable(entry.path) == 1 then
        lines = vim.fn.readfile(entry.path)
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    vim.bo[buf].buftype   = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile  = false
    if vim.api.nvim_buf_is_valid(entry.bufnr) then
        vim.bo[buf].filetype = vim.bo[entry.bufnr].filetype
    end
    vim.bo[buf].modifiable = false
    -- The buffer id keeps the name unique, so the saved scratch for a file can
    -- never clash with a not-yet-wiped predecessor (rapid re-selection).
    vim.api.nvim_buf_set_name(buf, ("unsaved://saved/%d/%s"):format(buf, entry.rel))
    return buf
end

--- Register the autocmds that tear the session down when the user closes either
--- diff window or the whole tab.
local function _register_autocmds()
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

--- Open the side-by-side diff for a single chosen entry in a fresh tab: the
--- read-only on-disk scratch on the left, the live (unsaved) buffer on the
--- right, in native diff mode.
---@param entry keystone.unsaved.Entry
local function _open_diff(entry)
    -- Selecting again replaces any session still open.
    if _layout.group then _cleanup() end
    if not vim.api.nvim_buf_is_valid(entry.bufnr) then return end

    _layout.group = vim.api.nvim_create_augroup("keystone.unsaved", { clear = true })

    vim.cmd.tabnew()
    _layout.tab      = vim.api.nvim_get_current_tabpage()

    _layout.left_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(_layout.left_win, _make_saved_buf(entry))

    vim.cmd("rightbelow vsplit")
    _layout.right_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(_layout.right_win, entry.bufnr)

    _register_autocmds()

    vim.api.nvim_win_call(_layout.left_win, vim.cmd.diffthis)
    vim.api.nvim_win_call(_layout.right_win, vim.cmd.diffthis)

    -- Land on the live side so edits go to the real buffer.
    vim.api.nvim_set_current_win(_layout.right_win)
end

--- List the modified buffers in a picker and diff whichever one the user picks.
function M.open()
    local entries = _collect_entries()
    if #entries == 0 then
        vim.notify("[keystone] No modified buffers to diff", vim.log.levels.INFO)
        return
    end

    pick_select.select(entries, {
        prompt      = "Diff unsaved",
        ---@param entry keystone.unsaved.Entry
        format_item = function(entry) return entry.status .. "  " .. entry.rel end,
        -- Preview the live (unsaved) buffer so its current contents are visible
        -- before choosing; the picker shows it read-only in its float.
        ---@param entry keystone.unsaved.Entry
        preview_item = function(entry)
            if vim.api.nvim_buf_is_valid(entry.bufnr) then
                return { buf = entry.bufnr }
            end
        end,
    }, function(choice)
        if choice then _open_diff(choice) end
    end)
end

return M
