local M           = {}

---@class keystone.bookmarks.Config
---@field enabled boolean
---@field persist_path (string | fun():string)?  -- bookmarks file path; nil = vim.fn.stdpath("data")/keystone/bookmarks.json
---@field sign_text string
---@field sign_hl string

---@class keystone.bookmarks.Entry
---@field file string    -- absolute path
---@field lnum integer   -- 1-based line number
---@field label string?  -- optional user-facing label

local store       = require("keystone.bookmarks.store")
local inputwin    = require("keystone.tk.inputwin")
local ui          = require("keystone.tk.ui")
local picker      = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local extmarks    = require("keystone.tk.extmarks")
local Signal      = require("keystone.tk.Signal")

-- Emitted whenever the bookmark set changes, so open views can refresh.
---@type keystone.tk.Signal<fun()>
local _changed    = Signal.new()

---@type keystone.tk.extmarks.GroupFunctions
local _mark_group

---@type vim.api.keyset.set_extmark
local _mark_opts

---@type keystone.bookmarks.Config
local _config

local _next_id    = 0

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

-- Persist the current bookmarks. The extmark group is the single source of
-- truth; the store just serializes the disk-consistent snapshot we hand it.
local function _persist()
    store.save(_read_entries(false), _config)
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
    _changed:emit()
end

---@param file string
---@param lnum integer
---@return boolean removed
local function _delete_loc(file, lnum)
    local mark = _mark_group.get_extmark_by_location(file, lnum, true)
    if not mark then return false end
    _mark_group.remove_extmark(mark.id)
    _persist()
    _changed:emit()
    return true
end

---@param file string
---@return string
local function _relpath(file)
    return vim.fn.fnamemodify(file, ":~:.")
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
        _changed:emit()
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
        _changed:emit()
    end)
end

---@return keystone.bookmarks.Entry[]
function M.get_entries()
    return _read_entries()
end

function M.pick()
    local entries = _read_entries()
    if #entries == 0 then
        vim.notify("[keystone] No bookmarks set", vim.log.levels.WARN)
        return
    end

    local cur_file, cur_lnum = _get_cur_loc()
    if cur_file then cur_file = _norm(cur_file) end

    table.sort(entries, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.lnum < b.lnum
    end)

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

--- Opens an interactive quickfix-style split editor for bookmarks. Each edit is
--- applied immediately: edit label (r), remove (d) and undo (u); <CR> opens the
--- bookmark under the cursor. The list refreshes live when bookmarks change.
function M.open_list()
    require("keystone.bookmarks.list_editor").open({
        get_entries = _read_entries,
        delete = function(file, lnum)
            _delete_loc(file, lnum)
        end,
        upsert = function(file, lnum, label)
            _upsert(file, lnum, label)
        end,
        subscribe = function(fn)
            return _changed:subscribe(fn)
        end,
    })
end

---@param opts keystone.bookmarks.Config?
function M.setup(opts)
    _config  = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
    M.config = _config

    if not _config.enabled then return end

    _mark_group  = extmarks.define_group("keystone_bookmarks", { priority = 20 })
    _mark_opts   = { sign_text = _config.sign_text, sign_hl_group = _config.sign_hl }

    local stored = store.load(_config)
    for _, e in ipairs(stored) do
        _mark_group.set_file_extmark(_new_id(), e.file, e.lnum, 0, _mark_opts, { label = e.label })
    end

    -- NB: distinct from the extmark group's augroup. `define_group("keystone_bookmarks")`
    -- registers the BufReadPost/BufWritePost/BufUnload sync autocmds under an augroup
    -- of that same name; reusing it here with clear=true would wipe them out.
    vim.api.nvim_create_autocmd("VimLeave", {
        group    = vim.api.nvim_create_augroup("keystone_bookmarks_persist", { clear = true }),
        callback = _persist,
    })

    require("keystone.tk.usercmd").register_user_cmd("Bookmark",
        function(cmd, args, cmd_opts)
            require("keystone.bookmarks.command").run_command(cmd, args, cmd_opts)
        end,
        {
            desc          = "Persistent line bookmarks",
            subcommand_fn = function(cmd, rest)
                return require("keystone.bookmarks.command").get_subcommands(cmd, rest)
            end,
        })
end

return M
