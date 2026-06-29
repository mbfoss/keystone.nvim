local M           = {}

---@class keystone.bookmarks.Config
---@field enabled boolean
---@field persist_dir (string | fun():string)?  -- nil = vim.fn.stdpath("data")
---@field sign_text string
---@field sign_hl string

---@class keystone.bookmarks.Entry
---@field name string   -- unique identifier
---@field file string   -- absolute path
---@field lnum integer  -- 1-based line number

local store       = require("keystone.bookmarks.store")
local inputwin    = require("keystone.util.inputwin")
local uitool      = require("keystone.util.uitool")
local picker      = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local extmarks    = require("keystone.util.extmarks")
local ListEditor  = require("keystone.util.ListEditor")

---@type keystone.bookmarks.extmarks.GroupFunctions
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
        enabled     = true,
        persist_dir = nil,
        sign_text   = "*",
        sign_hl     = "DiagnosticInfo",
    }
end

M.config = _get_default_config()

local function _norm(file)
    if not file or file == "" then return file end
    return vim.fn.fnamemodify(file, ":p")
end

---@return keystone.bookmarks.Entry[]
local function _read_entries()
    local marks = _mark_group.get_extmarks(true)
    local entries = {}
    for _, m in ipairs(marks) do
        if m.user_data and m.user_data.name then
            entries[#entries + 1] = {
                name = m.user_data.name,
                file = m.file,
                lnum = m.lnum,
            }
        end
    end
    return entries
end

local function _persist()
    store.save(_config)
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
    local file = vim.fn.expand("%:p")
    if file == "" then
        return
    end
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    return file, lnum
end


---@param name string
---@param file string
---@param lnum integer
local function _upsert(name, file, lnum)
    local by_loc = _mark_group.get_extmark_by_location(file, lnum, true)
    if by_loc then
        store.delete(file, lnum)
        _mark_group.remove_extmark(by_loc.id)
    end

    store.add({ name = name, file = file, lnum = lnum })
    _mark_group.set_file_extmark(_new_id(), file, lnum, 0, _mark_opts, { name = name })
    _persist()
end

---@param file string
---@param lnum integer
---@return boolean removed
local function _delete_loc(file, lnum)
    local mark = _mark_group.get_extmark_by_location(file, lnum, true)
    if not mark then return false end
    store.delete(file, lnum)
    _mark_group.remove_extmark(mark.id)
    _persist()
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
    local existing = _mark_group.get_extmark_by_location(file, lnum, true)
    local default = existing and existing.user_data.name or ""
    inputwin.open({ prompt = "Bookmark", default = default }, function(name)
        if not name or name:match("^%s*$") then return end
        name = name:match("^%s*(.-)%s*$")
        _upsert(name, file, lnum)
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
    uitool.confirm_action("Clear bookmarks in current file", false, function(accepted)
        if not accepted then return end
        local marks = _mark_group.get_file_extmarks(file, false)
        local before = #marks
        for _, m in ipairs(marks) do store.delete(m.file, m.lnum) end
        _mark_group.remove_file_extmarks(file)
        _persist()
    end)
end

function M.clear_all()
    if #_mark_group.get_extmarks(false) == 0 then
        return
    end
    uitool.confirm_action("Clear all bookmarks", false, function(accepted)
        if not accepted then return end
        for _, m in ipairs(_mark_group.get_extmarks(false)) do store.delete(m.file, m.lnum) end
        _mark_group.remove_extmarks()
        _persist()
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
                local match = pickertools.match_label(entry.name, query)
                if match then
                    local relpath = vim.fn.fnamemodify(entry.file, ":~:.")
                    local loc_chunk = {relpath .. ":" .. entry.lnum, "@namespace" }
                    ---@type keystone.Picker.Item
                    local item = {
                        label_chunks = match.chunks,
                        virt_lines   = { { loc_chunk } },
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
            uitool.smart_open_file(data.filepath, data.lnum, data.col)
        end
    end)
end

---@param file string
---@param lnum integer
---@return string
local function _loc_key(file, lnum)
    return file .. "\0" .. lnum
end

--- Builds a manager item for a bookmark at `file`:`lnum` named `name`.
---@param name string
---@param file string
---@param lnum integer
---@return keystone.ListEditor.Item
local function _make_item(name, file, lnum)
    local loc_chunk = { _relpath(file) .. ":" .. lnum, "@namespace" }
    ---@type keystone.ListEditor.Item
    return {
        key          = _loc_key(file, lnum),
        label_chunks = { { name, "Normal" } },
        virt_lines   = { { loc_chunk } },
        data         = { name = name, filepath = file, lnum = lnum },
    }
end

--- Builds the manager list from the current bookmarks, sorted by file then line.
---@return keystone.ListEditor.Item[]
local function _manager_items()
    local entries = _read_entries()
    table.sort(entries, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.lnum < b.lnum
    end)

    local items = {}
    for _, entry in ipairs(entries) do
        items[#items + 1] = _make_item(entry.name, entry.file, entry.lnum)
    end
    return items
end

--- Reconciles the manager's committed list against the stored bookmarks:
--- upserts new/renamed entries and deletes ones that are no longer present.
---@param items keystone.ListEditor.Item[]
local function _commit(items)
    local original = {}
    for _, entry in ipairs(_read_entries()) do
        original[_loc_key(entry.file, entry.lnum)] = entry
    end

    local seen = {}
    for _, item in ipairs(items) do
        local data = item.data
        local key = _loc_key(data.filepath, data.lnum)
        seen[key] = true
        local orig = original[key]
        if not orig or orig.name ~= data.name then
            _upsert(data.name, data.filepath, data.lnum)
        end
    end

    for key, entry in pairs(original) do
        if not seen[key] then
            _delete_loc(entry.file, entry.lnum)
        end
    end
end

--- Opens an interactive editor for named bookmarks: add (a), edit (r), remove
--- (d) and undo (u), with a live file preview. Edits are buffered on a working
--- list and only written when confirmed with <CR>; <Esc> discards them.
function M.manager()
    local origin_file, origin_lnum = _get_cur_loc()
    if origin_file then origin_file = _norm(origin_file) end

    ListEditor.open({
        prompt          = "Bookmarks",
        enable_preview  = true,
        enable_list_sep = true,
        empty_text      = "No bookmarks",
        initial_key     = (origin_file and origin_lnum)
            and _loc_key(origin_file, origin_lnum) or nil,

        finder          = function()
            return _manager_items()
        end,

        create_item     = function(done)
            if not origin_file or not origin_lnum then
                vim.notify("[keystone] No valid file to bookmark", vim.log.levels.WARN)
                return done(nil)
            end
            inputwin.open({ prompt = "Bookmark" }, function(input)
                local name = input and vim.trim(input) or ""
                if name == "" then return done(nil) end
                done(_make_item(name, origin_file, origin_lnum))
            end)
        end,

        update_item     = function(item, done)
            local data = item.data
            inputwin.open({ prompt = "Rename", default = data.name }, function(input)
                local name = input and vim.trim(input) or ""
                if name == "" then return done(nil) end
                done(_make_item(name, data.filepath, data.lnum))
            end)
        end,

        on_commit       = _commit,
    })
end

---@param opts keystone.bookmarks.Config?
function M.setup(opts)
    _config  = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
    M.config = _config

    if not _config.enabled then return end

    _mark_group  = extmarks.define_group("bookmarks", { priority = 20 })
    _mark_opts   = { sign_text = _config.sign_text, sign_hl_group = _config.sign_hl }

    local stored = store.load(_config)
    for _, e in ipairs(stored) do
        _mark_group.set_file_extmark(_new_id(), e.file, e.lnum, 0, _mark_opts, { name = e.name })
    end

    vim.api.nvim_create_autocmd("VimLeave", {
        group    = vim.api.nvim_create_augroup("keystone_bookmarks", { clear = true }),
        callback = _persist,
    })

    require("keystone.util.usercmd").register_user_cmd("Bookmark",
        function(cmd, args, cmd_opts)
            require("keystone.bookmarks.command").run_command(cmd, args, cmd_opts)
        end,
        {
            desc          = "Named bookmarks",
            subcommand_fn = function(cmd, rest)
                return require("keystone.bookmarks.command").get_subcommands(cmd, rest)
            end,
        })
end

return M
