local M            = {}

---@class keystone.bookmarks.Config
---@field enabled boolean
---@field persist_path (string | fun():string)?  -- bookmarks file path; nil = ~/.nvimbookmarks
---@field sign_text string
---@field sign_hl string

---@class keystone.bookmarks.Entry
---@field file string    -- absolute path
---@field lnum integer   -- 1-based line number
---@field label string?  -- optional user-facing label

local fsutil       = require("keystone.tk.fsutil")
local inputwin     = require("keystone.tk.inputwin")
local ui           = require("keystone.tk.ui")
local picker       = require("keystone.pick.base.picker")
local pickertools  = require("keystone.pick.base.pickertools")
local extmarks     = require("keystone.tk.extmarks")
local fixedwin     = require("keystone.tk.fixedwin")

-- Height ratio of the bookmarks list split, tracked live by fixedwin and reused
-- so reopening the list keeps the height the user last dragged it to.
local _list_ratio  = 0.25

---@type keystone.tk.extmarks.GroupFunctions
local _mark_group

---@type vim.api.keyset.set_extmark
local _mark_opts

---@type keystone.bookmarks.Config
local _config

local _next_id     = 0

local function _new_id()
    _next_id = _next_id + 1
    return _next_id
end

local function _get_default_config()
    ---@type keystone.bookmarks.Config
    return {
        enabled      = true,
        persist_path = nil,
        sign_text    = "*",
        sign_hl      = "DiagnosticInfo",
    }
end

M.config = _get_default_config()

----------- STORE -----------
-- The bookmarks file is a plain, human-editable text file. Each non-empty line is
--
--     <path>:<lnum>[  <label>]
--
-- where <path> is home-relative (`~/...`) when under $HOME, else absolute, and an
-- optional label follows the location after whitespace. Blank lines are ignored.

---@return string
local function _store_filepath()
    local pp = _config.persist_path
    if type(pp) == "function" then
        pp = pp()
    end
    if type(pp) == "string" and pp ~= "" then
        return vim.fs.normalize(pp)
    end
    return vim.fs.normalize("~/.nvimbookmarks")
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

---@param entry keystone.bookmarks.Entry
---@return string
local function _encode_entry(entry)
    local rel = _encode_path(entry.file)
    if entry.label and entry.label ~= "" then
        return string.format("%s:%d  %s", rel, entry.lnum, entry.label)
    end
    return string.format("%s:%d", rel, entry.lnum)
end

---@param line string
---@return keystone.bookmarks.Entry?
local function _decode_line(line)
    -- Non-greedy path up to the first `:<digits>`; anything after is the label.
    local path, lnum, label = line:match("^%s*(.-):(%d+)%s*(.-)%s*$")
    if not path or path == "" then return nil end
    if label == "" then label = nil end
    return { file = _decode_path(path), lnum = tonumber(lnum), label = label }
end

---@return keystone.bookmarks.Entry[]
local function _store_load()
    local ok, raw = fsutil.read_content(_store_filepath())
    if not ok or raw == "" then return {} end

    local entries = {}
    for line in raw:gmatch("[^\r\n]+") do
        local entry = _decode_line(line)
        if entry then entries[#entries + 1] = entry end
    end
    return entries
end

---@param entries keystone.bookmarks.Entry[]
local function _store_save(entries)
    local path = _store_filepath()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

    local lines = {}
    for _, e in ipairs(entries) do
        lines[#lines + 1] = _encode_entry(e)
    end
    local content = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
    fsutil.write_content(path, content)
end

local function _norm(file)
    if not file or file == "" then return file end
    return vim.fn.fnamemodify(file, ":p")
end

-- Snapshot the group's bookmarks. `live` (default true) reports current buffer
-- positions -- right for display, where marks follow in-buffer edits. Pass false
-- for the disk-consistent positions (synced on write/unload) used when persisting.
---@param live boolean?
---@return keystone.bookmarks.Entry[]
local function _read_entries(live)
    if live == nil then live = true end
    local marks = _mark_group.get_extmarks(live)
    local entries = {}
    for _, m in ipairs(marks) do
        entries[#entries + 1] = {
            file  = m.file,
            lnum  = m.lnum,
            label = m.user_data and m.user_data.label or nil,
        }
    end
    return entries
end

---@return keystone.bookmarks.Entry[]
local function _sorted_entries(live)
    local entries = _read_entries(live)
    table.sort(entries, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.lnum < b.lnum
    end)
    return entries
end

-- Persist the current bookmarks. The extmark group is the single source of truth;
-- the store just serializes the disk-consistent snapshot we hand it.
local function _persist()
    _store_save(_sorted_entries(false))
end

-- Rebuild the extmark group (the signs) from the bookmarks file on disk. This is
-- the "saving the file synchronises the signs" path: after the user edits and
-- writes the plain bookmarks file, its content becomes authoritative.
local function _sync_from_file()
    _mark_group.remove_extmarks()
    for _, e in ipairs(_store_load()) do
        _mark_group.set_file_extmark(_new_id(), e.file, e.lnum, 0, _mark_opts, { label = e.label })
    end
end

-- After a mutation persists to disk, refresh the bookmarks file buffer if it is
-- open and unmodified so the user sees the change without a manual reload.
local function _refresh_open_file_buffer()
    local path = _store_filepath()
    local bufnr = vim.fn.bufnr(path)
    if bufnr < 0 or not vim.api.nvim_buf_is_loaded(bufnr) then return end
    if vim.bo[bufnr].modified then return end
    vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent! edit")
    end)
end

---@return string|nil,number|nil
local function _get_cur_loc()
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

---@param file string
---@param lnum integer
---@param label string?
local function _upsert(file, lnum, label)
    local by_loc = _mark_group.get_extmark_by_location(file, lnum, true)
    if by_loc then
        _mark_group.remove_extmark(by_loc.id)
    end

    _mark_group.set_file_extmark(_new_id(), file, lnum, 0, _mark_opts, { label = label })
    _persist()
    _refresh_open_file_buffer()
end

---@param file string
---@param lnum integer
---@return boolean removed
local function _delete_loc(file, lnum)
    local mark = _mark_group.get_extmark_by_location(file, lnum, true)
    if not mark then return false end
    _mark_group.remove_extmark(mark.id)
    _persist()
    _refresh_open_file_buffer()
    return true
end

----------- PUBLIC API -----------

function M.set_at_cursor()
    local file, lnum = _get_cur_loc()
    if not file or not lnum then
        vim.notify("[keystone] No valid file at cursor", vim.log.levels.WARN)
        return
    end
    file = _norm(file)
    if _mark_group.get_extmark_by_location(file, lnum, true) then return end
    _upsert(file, lnum, nil)
end

function M.set_label_at_cursor()
    local file, lnum = _get_cur_loc()
    if not file or not lnum then
        vim.notify("[keystone] No valid file at cursor", vim.log.levels.WARN)
        return
    end
    file = _norm(file)
    local existing = _mark_group.get_extmark_by_location(file, lnum, true)
    local default = (existing and existing.user_data and existing.user_data.label) or ""
    inputwin.open({ prompt = "Bookmark label", default = default }, function(label)
        if not label then return end
        label = label:match("^%s*(.-)%s*$")
        _upsert(file, lnum, label ~= "" and label or nil)
    end)
end

function M.delete_at_cursor()
    local file, lnum = _get_cur_loc()
    if not file or not lnum then return end
    _delete_loc(_norm(file), lnum)
end

function M.clear_file()
    local buf = vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local file = _norm(vim.api.nvim_buf_get_name(buf))
    if not file or file == "" then return end
    ui.confirm_action("Clear bookmarks in current file", false, function(accepted)
        if not accepted then return end
        _mark_group.remove_file_extmarks(file)
        _persist()
        _refresh_open_file_buffer()
    end)
end

function M.clear_all()
    if #_mark_group.get_extmarks(false) == 0 then
        return
    end
    ui.confirm_action("Clear all bookmarks", false, function(accepted)
        if not accepted then return end
        _mark_group.remove_extmarks()
        _persist()
        _refresh_open_file_buffer()
    end)
end

---@return keystone.bookmarks.Entry[]
function M.get_entries()
    return _read_entries()
end

function M.pick()
    local entries = _sorted_entries()
    if #entries == 0 then
        vim.notify("[keystone] No bookmarks set", vim.log.levels.WARN)
        return
    end

    local cur_file, cur_lnum = _get_cur_loc()
    if cur_file then cur_file = _norm(cur_file) end

    picker.open({
        prompt          = "Bookmarks",
        enable_preview  = true,
        enable_list_sep = true,
        finder          = function(query, _, _fetch_opts, callback)
            local items = {}
            for _, entry in ipairs(entries) do
                local relpath = vim.fn.fnamemodify(entry.file, ":~:.")
                local loc_text = relpath .. ":" .. entry.lnum
                local match = pickertools.match_label(loc_text, query)
                if match then
                    ---@type keystone.Picker.Item
                    local item = {
                        label_chunks = match.chunks,
                        virt_lines   = entry.label and { { { entry.label, "@text.note" } } } or nil,
                        score        = match.score,
                        data         = {
                            filepath = entry.file,
                            lnum     = entry.lnum,
                            col      = 0,
                        },
                    }
                    if cur_file and entry.file == cur_file and entry.lnum == cur_lnum then
                        item.initial = true
                    end
                    table.insert(items, item)
                end
            end
            callback(items)
        end,
    }, function(data)
        if data and data.filepath then
            ui.smart_open_file(data.filepath, data.lnum, data.col)
        end
    end)
end

--- Opens the plain bookmarks file for editing in a split. It is an ordinary file
--- buffer: edit lines freely, then `:w` to synchronise the signs (see setup's
--- BufWritePost autocmd). Each line is `<path>:<lnum>[  <label>]`.
function M.open_list()
    -- Ensure the on-disk file reflects current (live) sign positions before the
    -- user starts editing it.
    _persist()

    local path = _store_filepath()
    local existing = vim.fn.bufnr(path)
    if existing >= 0 then
        local existing_win = vim.fn.bufwinid(existing)
        if existing_win >= 0 then
            vim.api.nvim_set_current_win(existing_win)
            return
        end
    end

    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    vim.bo[bufnr].buflisted = true

    -- A height-pinned split whose ratio fixedwin tracks across resizes/layout
    -- changes; persist the last-known ratio so reopening keeps the chosen height.
    local win = fixedwin.create_fixed_win("height", _list_ratio, function(ratio)
        _list_ratio = ratio
    end, { enter = true })
    vim.api.nvim_win_set_buf(win, bufnr)
    vim.wo[win].winfixbuf = true
end

----------- COMMAND -----------

local _subcommand_list = { "set", "setlabel", "delete", "pick", "list", "clear_file", "clear_all" }

---@param _ string
---@param rest string[]
---@return string[]
local function _get_subcommands(_, rest)
    if #rest == 0 then return _subcommand_list end
    return {}
end

---@param _ string
---@param args string[]
---@param _opts vim.api.keyset.create_user_command.command_args
local function _run_command(_, args, _opts)
    local cmd = args[1] or "set"
    if cmd == "set" then
        M.set_at_cursor()
    elseif cmd == "setlabel" then
        M.set_label_at_cursor()
    elseif cmd == "delete" then
        M.delete_at_cursor()
    elseif cmd == "pick" then
        M.pick()
    elseif cmd == "list" then
        M.open_list()
    elseif cmd == "clear_file" then
        M.clear_file()
    elseif cmd == "clear_all" then
        M.clear_all()
    else
        vim.notify("[keystone] Unknown Bookmarks subcommand: " .. tostring(cmd), vim.log.levels.WARN)
    end
end

---@param opts keystone.bookmarks.Config?
function M.setup(opts)
    _config  = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
    M.config = _config

    if not _config.enabled then return end

    _mark_opts = { sign_text = _config.sign_text, sign_hl_group = _config.sign_hl }

    if not _mark_group then
        _mark_group = extmarks.define_group("keystone_bookmarks", { priority = 20 })

        for _, e in ipairs(_store_load()) do
            _mark_group.set_file_extmark(_new_id(), e.file, e.lnum, 0, _mark_opts, { label = e.label })
        end
    end

    local augroup = vim.api.nvim_create_augroup("keystone_bookmarks", { clear = true })
    vim.api.nvim_create_autocmd("VimLeave", {
        group    = augroup,
        callback = _persist,
    })
    -- Writing the bookmarks file makes its content authoritative for the signs.
    vim.api.nvim_create_autocmd("BufWritePost", {
        group    = augroup,
        pattern  = _store_filepath(),
        callback = _sync_from_file,
    })

    require("keystone.tk.usercmd").register_user_cmd("Bookmark", _run_command, {
        desc          = "Persistent line bookmarks",
        subcommand_fn = _get_subcommands,
    })
end

return M
