local M = {}

-- ---------------------------------------------------------------------------
-- keystone.diff
--
-- A side-by-side diff of arbitrary filesystem paths, exposing two commands:
--
--   :DiffFiles <a> <b>   diff two individual files
--   :DiffDirs  <a> <b>   diff two directory trees; the files that differ are
--                        listed in a location list, navigated with the native
--                        diff shown side-by-side for the selected entry
--
-- Modelled on the git-driven diff in gittools.nvim, but content comes from the
-- filesystem (`readfile`/live buffers) rather than `git show`. A session owns
-- its two split windows, generated scratch buffers, and (for DiffDirs) the
-- location list; on teardown it collapses back to a single window so the
-- original layout is restored.
-- ---------------------------------------------------------------------------

local _usercmd = require("keystone.tk.usercmd")

--- One entry in a diff session: the pair of files compared on each side.
--- Either side's path may be nil when the file exists on only one side
--- (added/deleted); such a side is shown as an empty scratch buffer.
---@class keystone.diff.Entry
---@field left_path  string?  absolute path on the left side; nil if added
---@field right_path string?  absolute path on the right side; nil if deleted
---@field status     "A"|"M"|"D" single-letter status
---@field display    string   relative path shown in the location list

--- One diff session, living in a vertical split of the window it was launched
--- from. It owns its two split windows, the generated scratch buffers, and any
--- location list attached to its right window.
---@class keystone.diff.Session
---@field group       integer   augroup id for this session's autocmds
---@field left_win    integer?  window for the left side
---@field right_win   integer?  window for the right side; owns the loclist
---@field loclist_win integer?  the location-list window
---@field buffers     integer[] generated scratch buffers to delete on close
---@field entry       keystone.diff.Entry? the single entry, when there is no loclist
---@field closing     boolean   reentrancy guard for _close_session
---@field setting_up  boolean   reentrancy guard to stop infinite event loops

local _ENTRY_KEY = "keystone.diff"

-- setloclist `title`, used both to populate the list and to recognize (in the
-- QuickFixCmdPost guard below) whether the right window's location list is
-- still ours or has been overwritten by an unrelated :lvimgrep/:laddexpr.
local _LOCLIST_TITLE = "Keystone Diff"

---@type keystone.diff.Session[]
local _sessions = {}
local _next_id  = 0

-- Status letters rendered at the start of each location-list line, and the
-- highlight group each links to by default. Linked to the `Diagnostic*` groups
-- (foreground colors that stand out on a single character, and guaranteed to
-- exist) rather than `Diff*` (mostly whole-line background fills).
local _STATUS_HL = {
    A = { "KeystoneDiffAdded",    "DiagnosticOk" },
    M = { "KeystoneDiffModified", "DiagnosticWarn" },
    D = { "KeystoneDiffDeleted",  "DiagnosticError" },
}

for _, pair in pairs(_STATUS_HL) do
    vim.api.nvim_set_hl(0, pair[1], { link = pair[2], default = true })
end

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[keystone.diff] " .. msg, level or vim.log.levels.INFO)
end

--- Color each location-list line by its leading status letter. Scoped to
--- `bufnr` alone so it can't bleed into unrelated location-list windows.
---@param bufnr integer
local function _highlight_loclist(bufnr)
    vim.api.nvim_buf_call(bufnr, function()
        for status, pair in pairs(_STATUS_HL) do
            vim.cmd(string.format([[syntax match %s /^%s\>/]], pair[1], status))
        end
    end)
end

--- Tear down `session`: drop its autocmds, close the location list, collapse
--- the side-by-side split back to a single surviving window, and delete its
--- generated scratch buffers. Safe to invoke at any point, whichever of the
--- split windows or the loclist the user closed.
---@param session keystone.diff.Session
local function _close_session(session)
    if session.closing then return end
    session.closing = true

    for i, s in ipairs(_sessions) do
        if s == session then
            table.remove(_sessions, i)
            break
        end
    end

    -- Drop the autocmds before closing anything, so the window closes below
    -- don't re-trigger teardown through our own WinClosed hooks.
    vim.api.nvim_del_augroup_by_id(session.group)

    -- The loclist window survives nvim_win_close of its owner; close it first.
    -- Prefer the window recorded at open time: once right_win (the list's
    -- owner) has itself been closed, getloclist can no longer locate the list.
    local llwin = session.loclist_win
    if not (llwin and vim.api.nvim_win_is_valid(llwin))
        and session.right_win and vim.api.nvim_win_is_valid(session.right_win) then
        local found = vim.fn.getloclist(session.right_win, { winid = 0 }).winid
        llwin = found ~= 0 and found or nil
    end
    if llwin and vim.api.nvim_win_is_valid(llwin) then
        pcall(vim.api.nvim_win_close, llwin, false)
    end
    session.loclist_win = nil

    -- Keep exactly one of the two split windows so the layout collapses back to
    -- a single window. Prefer the right side; fall back to the left.
    local left_valid  = session.left_win and vim.api.nvim_win_is_valid(session.left_win)
    local right_valid = session.right_win and vim.api.nvim_win_is_valid(session.right_win)
    local survivor    = (right_valid and session.right_win) or (left_valid and session.left_win) or nil

    for _, win in ipairs({ session.left_win, session.right_win }) do
        if win and win ~= survivor and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, false)
        end
    end
    if survivor and vim.api.nvim_win_is_valid(survivor) then
        vim.api.nvim_win_call(survivor, function() vim.cmd("diffoff") end)
    end
    session.left_win  = nil
    session.right_win = nil

    -- Delete the generated scratch buffers, sparing whichever one is still
    -- shown in the surviving window so it doesn't blank out under the user.
    local keep = survivor and vim.api.nvim_win_is_valid(survivor)
        and vim.api.nvim_win_get_buf(survivor) or nil
    for _, bufnr in ipairs(session.buffers) do
        if bufnr ~= keep and vim.api.nvim_buf_is_valid(bufnr) then
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
    end
    session.buffers = {}
end

--- Close every open diff session (e.g. on VimLeavePre).
function M.clear_session()
    -- _close_session removes the session from _sessions; iterate off a copy.
    for _, session in ipairs({ unpack(_sessions) }) do
        _close_session(session)
    end
end

--- Create an empty, read-only scratch buffer standing in for an absent side
--- (a file added or deleted between the two sides).
---@param session keystone.diff.Session
---@param side_label string "left" or "right"
---@param display string relative path this side would have held
---@param filetype string syntax highlighting to apply
---@return integer bufnr
local function _make_scratch_buf(session, side_label, display, filetype)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype    = "nofile"
    vim.bo[buf].bufhidden  = "wipe"
    vim.bo[buf].swapfile   = false
    vim.bo[buf].filetype   = filetype
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_set_name(buf, string.format("keystone-diff://%d/%s/%s", buf, side_label, display))
    table.insert(session.buffers, buf)
    return buf
end

--- Load the buffer for one side of an entry: the live/on-disk file when
--- `path` is set, or an empty scratch buffer when it is nil (absent side).
---@param session keystone.diff.Session
---@param path string? absolute path, or nil for an absent side
---@param side_label string "left" or "right"
---@param display string relative path shown for this entry
---@param filetype string syntax highlighting to apply
---@return integer bufnr
local function _side_buf(session, path, side_label, display, filetype)
    if path and vim.fn.filereadable(path) == 1 then
        local buf = vim.fn.bufadd(path)
        vim.fn.bufload(buf)
        return buf
    end
    return _make_scratch_buf(session, side_label, display, filetype)
end

--- Extract the session's current location-list item if it belongs to us.
---@param session keystone.diff.Session
---@return table? entry
local function _current_diff_entry(session)
    local win = session.right_win
    if not (win and vim.api.nvim_win_is_valid(win)) then return nil end
    local info = vim.fn.getloclist(win, { idx = 0, items = 1, size = 1 })
    if info.size == 0 then return nil end

    local entry = info.items[info.idx]
    if not (entry and entry.user_data and entry.user_data[_ENTRY_KEY]) then
        return nil
    end
    return entry
end

--- Drive the side-by-side splits from a diff entry's file pair.
---@param session keystone.diff.Session
---@param entry keystone.diff.Entry
local function _setup_diff(session, entry)
    if session.setting_up then return end
    session.setting_up = true

    local lw, rw = session.left_win, session.right_win
    if not (lw and vim.api.nvim_win_is_valid(lw) and rw and vim.api.nvim_win_is_valid(rw)) then
        session.setting_up = false
        return
    end

    local filetype = vim.filetype.match({ filename = entry.right_path or entry.left_path or entry.display }) or ""

    local right_buf = _side_buf(session, entry.right_path, "right", entry.display, filetype)
    local left_buf  = _side_buf(session, entry.left_path, "left", entry.display, filetype)

    vim.api.nvim_win_set_buf(lw, left_buf)
    vim.api.nvim_win_set_buf(rw, right_buf)

    vim.api.nvim_win_call(lw, function() vim.cmd("diffoff!") end)
    vim.api.nvim_win_call(rw, vim.cmd.diffthis)
    vim.api.nvim_win_call(lw, vim.cmd.diffthis)

    session.setting_up = false
end

--- Split the current window into the side-by-side diff layout, reusing the
--- launching window as the left side and a vertical split as the right side.
--- Closing either split window tears the session down.
---@param session keystone.diff.Session
local function _build_layout(session)
    session.left_win = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vsplit")
    session.right_win = vim.api.nvim_get_current_win()

    -- Defer teardown: closing further windows synchronously from WinClosed
    -- breaks Neovim's own mid-close bookkeeping (E445).
    for _, win in ipairs({ session.left_win, session.right_win }) do
        vim.api.nvim_create_autocmd("WinClosed", {
            group    = session.group,
            pattern  = tostring(win),
            callback = function() vim.schedule(function() _close_session(session) end) end,
        })
    end
end

--- Install the tracking hooks that re-run the side-by-side setup as the user
--- navigates the location list, and that tear the session down if an unrelated
--- command takes over the right window's location list.
---@param session keystone.diff.Session
local function _register_autocmds(session)
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group    = session.group,
        pattern  = "*",
        callback = function()
            -- Ignore BufWinEnter events fired synchronously by our own
            -- nvim_win_set_buf calls in _setup_diff.
            if session.setting_up then return end
            local win = vim.api.nvim_get_current_win()
            if win ~= session.left_win and win ~= session.right_win then return end
            local entry = _current_diff_entry(session)
            if not entry then return end
            vim.schedule(function() _setup_diff(session, entry.user_data[_ENTRY_KEY]) end)
        end,
    })

    vim.api.nvim_create_autocmd("QuickFixCmdPost", {
        group    = session.group,
        pattern  = "l*",
        callback = function()
            if not (session.right_win and vim.api.nvim_win_is_valid(session.right_win)) then
                return
            end
            local info = vim.fn.getloclist(session.right_win, { title = 1 })
            if info.title ~= _LOCLIST_TITLE then
                vim.schedule(function() _close_session(session) end)
            end
        end,
    })
end

--- Start a fresh session with the given entries. When `with_loclist` is true a
--- location list of the entries drives navigation; otherwise the single entry
--- is diffed immediately.
---@param entries keystone.diff.Entry[]
---@param with_loclist boolean
local function _open_session(entries, with_loclist)
    _next_id = _next_id + 1
    ---@type keystone.diff.Session
    local session = {
        group       = vim.api.nvim_create_augroup("keystone.diff." .. _next_id, { clear = true }),
        left_win    = nil,
        right_win   = nil,
        loclist_win = nil,
        buffers     = {},
        entry       = nil,
        closing     = false,
        setting_up  = false,
    }
    _sessions[#_sessions + 1] = session

    _build_layout(session)

    if not with_loclist then
        session.entry = entries[1]
        _setup_diff(session, entries[1])
        vim.api.nvim_set_current_win(session.right_win)
        return
    end

    _register_autocmds(session)

    local items = {}
    for _, entry in ipairs(entries) do
        items[#items + 1] = {
            filename  = entry.right_path or entry.left_path,
            text      = entry.status,
            user_data = { [_ENTRY_KEY] = entry },
        }
    end

    vim.fn.setloclist(session.right_win, {}, " ", {
        title            = _LOCLIST_TITLE,
        items            = items,
        quickfixtextfunc = function(info)
            local list = vim.fn.getloclist(info.winid, { id = info.id, items = 1 }).items
            local out = {}
            for i = info.start_idx, info.end_idx do
                local e  = list[i]
                local ud = e.user_data and e.user_data[_ENTRY_KEY]
                out[#out + 1] = string.format("%s %s", e.text or "*", ud and ud.display or e.filename)
            end
            return out
        end,
    })

    -- The loclist window can only be opened once its window has a list.
    vim.api.nvim_win_call(session.right_win, function() vim.cmd("botright lopen") end)
    local llwin = vim.fn.getloclist(session.right_win, { winid = 0 }).winid
    if llwin ~= 0 then
        session.loclist_win = llwin
        _highlight_loclist(vim.api.nvim_win_get_buf(llwin))
        -- Closing the location list on its own also collapses the session.
        vim.api.nvim_create_autocmd("WinClosed", {
            group    = session.group,
            pattern  = tostring(llwin),
            callback = function() vim.schedule(function() _close_session(session) end) end,
        })
    end
    vim.api.nvim_set_current_win(session.right_win)
    vim.cmd.lfirst()
end

--- Resolve a user-supplied path to an absolute path.
---@param path string
---@return string
local function _abspath(path)
    return vim.fn.fnamemodify(vim.fn.expand(path), ":p")
end

--- Whether the two on-disk files differ in content. Compares sizes first
--- (cheap) and only reads both when the sizes match.
---@param a string absolute path
---@param b string absolute path
---@return boolean
local function _files_differ(a, b)
    local sa, sb = vim.uv.fs_stat(a), vim.uv.fs_stat(b)
    if not (sa and sb) then return true end
    if sa.size ~= sb.size then return true end

    local fa = vim.fn.readfile(a, "b")
    local fb = vim.fn.readfile(b, "b")
    if #fa ~= #fb then return true end
    for i = 1, #fa do
        if fa[i] ~= fb[i] then return true end
    end
    return false
end

--- Collect the relative paths of every regular file under `dir` (recursively).
---@param dir string absolute directory path
---@return table<string, true> rels set of relative paths
local function _list_files(dir)
    local rels = {}
    for name, kind in vim.fs.dir(dir, { depth = math.huge }) do
        if kind == "file" then
            rels[name] = true
        end
    end
    return rels
end

--- Compare two directory trees into per-file change entries. A file present on
--- both sides yields an entry only if its contents differ.
---@param left_dir string absolute path
---@param right_dir string absolute path
---@return keystone.diff.Entry[]
local function _collect_dir_changes(left_dir, right_dir)
    local left  = _list_files(left_dir)
    local right = _list_files(right_dir)

    local all = {}
    for rel in pairs(left) do all[rel] = true end
    for rel in pairs(right) do all[rel] = true end

    local rels = vim.tbl_keys(all)
    table.sort(rels)

    local entries = {}
    for _, rel in ipairs(rels) do
        local lp = left_dir .. "/" .. rel
        local rp = right_dir .. "/" .. rel
        if left[rel] and right[rel] then
            if _files_differ(lp, rp) then
                entries[#entries + 1] = { left_path = lp, right_path = rp, status = "M", display = rel }
            end
        elseif left[rel] then
            entries[#entries + 1] = { left_path = lp, right_path = nil, status = "D", display = rel }
        else
            entries[#entries + 1] = { left_path = nil, right_path = rp, status = "A", display = rel }
        end
    end
    return entries
end

--- Diff two individual files side-by-side.
---@param a string? left path
---@param b string? right path
function M.diff_files(a, b)
    if not (a and b and a ~= "" and b ~= "") then
        _notify("DiffFiles requires two file paths", vim.log.levels.ERROR)
        return
    end
    local left, right = _abspath(a), _abspath(b)
    for _, p in ipairs({ left, right }) do
        if vim.fn.filereadable(p) ~= 1 then
            _notify("Not a readable file: " .. p, vim.log.levels.ERROR)
            return
        end
    end
    _open_session({
        { left_path = left, right_path = right, status = "M", display = vim.fn.fnamemodify(right, ":t") },
    }, false)
end

--- Diff two directory trees side-by-side, driven by a location list.
---@param a string? left directory
---@param b string? right directory
function M.diff_dirs(a, b)
    if not (a and b and a ~= "" and b ~= "") then
        _notify("DiffDirs requires two directory paths", vim.log.levels.ERROR)
        return
    end
    local left, right = _abspath(a), _abspath(b)
    for _, p in ipairs({ left, right }) do
        if vim.fn.isdirectory(p) ~= 1 then
            _notify("Not a directory: " .. p, vim.log.levels.ERROR)
            return
        end
    end

    local entries = _collect_dir_changes(left, right)
    if #entries == 0 then
        _notify("No differences found")
        return
    end
    _open_session(entries, true)
end

-- Exposed for testing.
M._files_differ       = _files_differ
M._list_files         = _list_files
M._collect_dir_changes = _collect_dir_changes

---@class keystone.diff.Config
---@field unused any

---@param opts keystone.diff.Config?
function M.setup(opts)
    _usercmd.register_user_cmd("DiffFiles", function(_, args)
        M.diff_files(args[1], args[2])
    end, {
        desc          = "Diff two files side-by-side",
        subcommand_fn = function(_, _, arg_lead) return vim.fn.getcompletion(arg_lead, "file") end,
    })

    _usercmd.register_user_cmd("DiffDirs", function(_, args)
        M.diff_dirs(args[1], args[2])
    end, {
        desc          = "Diff two directory trees side-by-side",
        subcommand_fn = function(_, _, arg_lead) return vim.fn.getcompletion(arg_lead, "dir") end,
    })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group    = vim.api.nvim_create_augroup("keystone.diff.leave", { clear = true }),
        callback = function() M.clear_session() end,
    })
end

return M
