local M = {}

-- ---------------------------------------------------------------------------
-- keystone.merge
--
-- A 3-way merge of arbitrary filesystem paths, in the classic mergetool
-- layout:
--
--   +--------+--------+--------+
--   | LOCAL  |  BASE  | REMOTE |   read-only, diff mode
--   +--------+--------+--------+
--   |         MERGED           |   editable working copy
--   +--------------------------+
--
--   :Merge3 <local> <base> <remote> [<output>]
--
-- LOCAL/BASE/REMOTE are shown as read-only scratch buffers. MERGED is a real,
-- editable file buffer (defaulting to the LOCAL path, i.e. resolve in place),
-- opened as it exists on disk. This tool does NOT run any merge itself: it is
-- meant to be launched *by* a VCS's mergetool machinery (e.g. git's
-- `merge.tool`), which has already written MERGED with the conflict markers.
-- Resolving is thus: edit MERGED, then `:w`. Buffer-local mappings in the
-- MERGED window pull a hunk from each side via `:diffget`; native `]c`/`[c`
-- jump between conflicts.
--
-- A session owns its four split windows and the generated scratch buffers; on
-- teardown it collapses back to a single window so the original layout is
-- restored.
-- ---------------------------------------------------------------------------

local _usercmd = require("keystone.tk.usercmd")

--- One merge session, living in the four-window layout of the window it was
--- launched from.
---@class keystone.merge.Session
---@field group      integer   augroup id for this session's autocmds
---@field local_win  integer?  window for the LOCAL side
---@field base_win   integer?  window for the BASE (common ancestor) side
---@field remote_win integer?  window for the REMOTE side
---@field merged_win integer?  window for the editable MERGED result
---@field buffers    integer[] generated scratch buffers to delete on close
---@field closing    boolean   reentrancy guard for _close_session

-- Only one merge runs at a time: starting a new one tears down the previous.
---@type keystone.merge.Session?
local _session = nil
local _next_id = 0

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[keystone.merge] " .. msg, level or vim.log.levels.INFO)
end

--- Tear down `session`: drop its autocmds, collapse the four-window layout back
--- to a single surviving window (preferring MERGED), and delete its generated
--- scratch buffers. Safe to invoke at any point, whichever window the user
--- closed. The MERGED buffer is a real file buffer and is never deleted.
---@param session keystone.merge.Session
local function _close_session(session)
    if session.closing then return end
    session.closing = true

    if _session == session then _session = nil end

    -- Drop the autocmds before closing anything, so the window closes below
    -- don't re-trigger teardown through our own WinClosed hooks.
    vim.api.nvim_del_augroup_by_id(session.group)

    local wins = { session.local_win, session.base_win, session.remote_win, session.merged_win }

    -- Keep exactly one window so the layout collapses back to a single window.
    -- Prefer MERGED (the result the user cares about); fall back to any valid.
    local survivor
    if session.merged_win and vim.api.nvim_win_is_valid(session.merged_win) then
        survivor = session.merged_win
    else
        for _, win in ipairs(wins) do
            if win and vim.api.nvim_win_is_valid(win) then
                survivor = win
                break
            end
        end
    end

    for _, win in ipairs(wins) do
        if win and win ~= survivor and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, false)
        end
    end
    if survivor and vim.api.nvim_win_is_valid(survivor) then
        vim.api.nvim_win_call(survivor, function() vim.cmd("diffoff") end)
    end
    session.local_win  = nil
    session.base_win   = nil
    session.remote_win = nil
    session.merged_win = nil

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

--- Close the open merge session, if any (e.g. on VimLeavePre, or before
--- starting a fresh merge).
function M.clear_session()
    if _session then _close_session(_session) end
end

--- Create a read-only scratch buffer holding one side's on-disk contents.
---@param session keystone.merge.Session
---@param path string absolute path to read
---@param label string "LOCAL"|"BASE"|"REMOTE"
---@param filetype string syntax highlighting to apply
---@return integer bufnr
local function _make_side_buf(session, path, label, filetype)
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype    = "nofile"
    vim.bo[buf].bufhidden  = "wipe"
    vim.bo[buf].swapfile   = false
    vim.bo[buf].filetype   = filetype
    vim.bo[buf].modifiable = false
    -- set_lines marked the scratch buffer modified; clear it so window closes
    -- aren't blocked by E445 when 'hidden' is off.
    vim.bo[buf].modified   = false
    vim.api.nvim_buf_set_name(buf, string.format("keystone-merge://%s/%s", label, vim.fn.fnamemodify(path, ":t")))
    table.insert(session.buffers, buf)
    return buf
end

--- Build the four-window mergetool layout, reusing the launching window as
--- LOCAL. Closing any of the four windows tears the session down and collapses
--- back to a single window.
---@param session keystone.merge.Session
local function _build_layout(session)
    session.local_win = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vsplit")
    session.base_win = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vsplit")
    session.remote_win = vim.api.nvim_get_current_win()
    vim.cmd("botright split")
    session.merged_win = vim.api.nvim_get_current_win()

    -- Defer teardown: closing further windows synchronously from WinClosed
    -- breaks Neovim's own mid-close bookkeeping (E445).
    for _, win in ipairs({ session.local_win, session.base_win, session.remote_win, session.merged_win }) do
        vim.api.nvim_create_autocmd("WinClosed", {
            group    = session.group,
            pattern  = tostring(win),
            callback = function() vim.schedule(function() _close_session(session) end) end,
        })
    end
end

--- Install the buffer-local `:diffget` mappings in the MERGED window that pull
--- a hunk from each source buffer.
---@param merged_buf integer
---@param sources { key: string?, buf: integer, label: string }[]
local function _install_mappings(merged_buf, sources)
    for _, src in ipairs(sources) do
        if src.key and src.key ~= "" then
            vim.keymap.set("n", src.key, function()
                vim.cmd("diffget " .. src.buf)
            end, { buffer = merged_buf, desc = "Merge: take " .. src.label .. " hunk" })
        end
    end
end

--- Resolve a user-supplied path to an absolute path.
---@param path string
---@return string
local function _abspath(path)
    return vim.fn.fnamemodify(vim.fn.expand(path), ":p")
end

--- Start a 3-way merge of three files, editing the result into `output`.
---@param local_arg string?
---@param base_arg string?
---@param remote_arg string?
---@param output_arg string? destination for the merged result; defaults to LOCAL
function M.merge3(local_arg, base_arg, remote_arg, output_arg)
    if not (local_arg and base_arg and remote_arg
            and local_arg ~= "" and base_arg ~= "" and remote_arg ~= "") then
        _notify("Merge3 requires <local> <base> <remote> [<output>]", vim.log.levels.ERROR)
        return
    end

    local local_path  = _abspath(local_arg)
    local base_path   = _abspath(base_arg)
    local remote_path = _abspath(remote_arg)
    local output_path = (output_arg and output_arg ~= "") and _abspath(output_arg) or local_path

    for _, p in ipairs({ local_path, base_path, remote_path }) do
        if vim.fn.filereadable(p) ~= 1 then
            _notify("Not a readable file: " .. p, vim.log.levels.ERROR)
            return
        end
    end

    local filetype = vim.filetype.match({ filename = output_path }) or ""

    -- One merge at a time: tear down any session still open before starting.
    M.clear_session()

    _next_id = _next_id + 1
    ---@type keystone.merge.Session
    local session = {
        group      = vim.api.nvim_create_augroup("keystone.merge." .. _next_id, { clear = true }),
        local_win  = nil,
        base_win   = nil,
        remote_win = nil,
        merged_win = nil,
        buffers    = {},
        closing    = false,
    }
    _session = session

    _build_layout(session)

    local local_buf  = _make_side_buf(session, local_path, "LOCAL", filetype)
    local base_buf   = _make_side_buf(session, base_path, "BASE", filetype)
    local remote_buf = _make_side_buf(session, remote_path, "REMOTE", filetype)

    -- MERGED is a real, editable file buffer pointed at the output path, shown
    -- exactly as it exists on disk: the invoking tool (e.g. git's mergetool)
    -- has already written it with the conflict markers.
    local merged_buf = vim.fn.bufadd(output_path)
    vim.fn.bufload(merged_buf)

    vim.api.nvim_win_set_buf(session.local_win, local_buf)
    vim.api.nvim_win_set_buf(session.base_win, base_buf)
    vim.api.nvim_win_set_buf(session.remote_win, remote_buf)
    vim.api.nvim_win_set_buf(session.merged_win, merged_buf)

    for _, win in ipairs({ session.local_win, session.base_win, session.remote_win, session.merged_win }) do
        vim.api.nvim_win_call(win, vim.cmd.diffthis)
    end

    -- Give the three top windows equal width. They share one row separated by
    -- two vertical dividers; sizing the first two equally leaves the remainder
    -- (any odd column) to the third.
    local each = math.floor((vim.o.columns - 2) / 3)
    if each > 0 then
        vim.api.nvim_win_set_width(session.local_win, each)
        vim.api.nvim_win_set_width(session.base_win, each)
    end

    _install_mappings(merged_buf, {
        { key = M.config.keymaps.get_local,  buf = local_buf,  label = "LOCAL" },
        { key = M.config.keymaps.get_base,   buf = base_buf,   label = "BASE" },
        { key = M.config.keymaps.get_remote, buf = remote_buf, label = "REMOTE" },
    })

    vim.api.nvim_set_current_win(session.merged_win)
end

---@class keystone.merge.Config
---@field keymaps keystone.merge.Keymaps buffer-local maps installed in MERGED

--- Buffer-local `:diffget` mappings for the MERGED window. Set any to `false`
--- (or "") to skip it. Defaults are `<localleader>`-prefixed to stay out of
--- the global namespace.
---@class keystone.merge.Keymaps
---@field get_local  string|false pull the hunk under the cursor from LOCAL
---@field get_base   string|false pull the hunk under the cursor from BASE
---@field get_remote string|false pull the hunk under the cursor from REMOTE

---@return keystone.merge.Config
local function _get_default_config()
    return {
        keymaps = {
            get_local  = "<localleader>1",
            get_base   = "<localleader>2",
            get_remote = "<localleader>3",
        },
    }
end

---@type keystone.merge.Config
M.config = _get_default_config()

---@param opts keystone.merge.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

    _usercmd.register_user_cmd("Merge3", function(_, args)
        M.merge3(args[1], args[2], args[3], args[4])
    end, {
        desc          = "3-way merge <local> <base> <remote> [<output>]",
        subcommand = function(_, _, arg_lead) return vim.fn.getcompletion(arg_lead, "file") end,
    })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group    = vim.api.nvim_create_augroup("keystone.merge.leave", { clear = true }),
        callback = function() M.clear_session() end,
    })
end

return M
