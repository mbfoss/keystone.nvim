local M = {}

---@class keystone.bookmarks.Config
---@field enabled boolean
---@field persist_dir (string | fun():string)?  -- nil = vim.fn.stdpath("data")
---@field sign_text string
---@field sign_hl string

---@class keystone.bookmarks.Entry
---@field name string   -- unique identifier
---@field file string   -- absolute path
---@field lnum integer  -- 1-based line number

local _SIGN_GROUP = "KeystoneBookmarks"
local _SIGN_NAME  = "KeystoneBookmark"

local _store      = require("keystone.bookmarks.store")
local _inputwin   = require("keystone.util.inputwin")
local _uitool     = require("keystone.util.uitool")
local _picker     = require("keystone.pick.base.picker")
local _pickertools = require("keystone.pick.base.pickertools")

---@type keystone.bookmarks.Entry[]
local _entries = {}

---@type keystone.bookmarks.Config
local _config

local function _get_default_config()
    ---@type keystone.bookmarks.Config
    return {
        enabled    = true,
        persist_dir = nil,
        sign_text  = "",
        sign_hl    = "DiagnosticInfo",
    }
end

M.config = _get_default_config()

local function _norm(file)
    if not file or file == "" then return file end
    return vim.fn.fnamemodify(file, ":p")
end

local function _refresh_signs()
    vim.fn.sign_unplace(_SIGN_GROUP)
    local loaded = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            local name = vim.api.nvim_buf_get_name(bufnr)
            if name ~= "" then
                loaded[vim.fn.fnamemodify(name, ":p")] = bufnr
            end
        end
    end
    local id = 1
    for _, entry in ipairs(_entries) do
        local bufnr = loaded[entry.file]
        if bufnr then
            vim.fn.sign_place(id, _SIGN_GROUP, _SIGN_NAME, bufnr, {
                lnum = entry.lnum,
                priority = 20,
            })
            id = id + 1
        end
    end
end

local function _persist()
    _store.save(_config, _entries)
end

---@param name string
---@param file string
---@param lnum integer
local function _upsert(name, file, lnum)
    local new_entries = {}
    for _, e in ipairs(_entries) do
        if e.name ~= name and not (e.file == file and e.lnum == lnum) then
            table.insert(new_entries, e)
        end
    end
    table.insert(new_entries, { name = name, file = file, lnum = lnum })
    _entries = new_entries
    _persist()
    _refresh_signs()
end

---@param file string
---@param lnum integer
---@return integer?
local function _find_by_location(file, lnum)
    for i, e in ipairs(_entries) do
        if e.file == file and e.lnum == lnum then return i end
    end
end

----------- PUBLIC API -----------

function M.set_at_cursor()
    local file, lnum = _uitool.get_current_file_and_line()
    if not file or not lnum then
        vim.notify("[keystone] No valid file at cursor", vim.log.levels.WARN)
        return
    end
    file = _norm(file)
    local existing_idx = _find_by_location(file, lnum)
    local default = existing_idx and _entries[existing_idx].name or ""
    _inputwin.open({ prompt = "Bookmark name", default_text = default }, function(name)
        if not name or name:match("^%s*$") then return end
        name = name:match("^%s*(.-)%s*$")
        _upsert(name, file, lnum)
    end)
end

function M.delete_at_cursor()
    local file, lnum = _uitool.get_current_file_and_line()
    if not file or not lnum then return end
    file = _norm(file)
    local idx = _find_by_location(file, lnum)
    if not idx then
        vim.notify("[keystone] No bookmark at current line", vim.log.levels.WARN)
        return
    end
    local name = _entries[idx].name
    table.remove(_entries, idx)
    _persist()
    _refresh_signs()
    vim.notify("[keystone] Deleted bookmark: " .. name)
end

---@param name string
function M.delete_by_name(name)
    local new_entries = {}
    local found = false
    for _, e in ipairs(_entries) do
        if e.name == name then
            found = true
        else
            table.insert(new_entries, e)
        end
    end
    if not found then
        vim.notify("[keystone] No bookmark named: " .. name, vim.log.levels.WARN)
        return
    end
    _entries = new_entries
    _persist()
    _refresh_signs()
end

function M.clear_file()
    local buf = vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local file = _norm(vim.api.nvim_buf_get_name(buf))
    if not file or file == "" then return end
    _uitool.confirm_action("Clear bookmarks in current file", false, function(accepted)
        if not accepted then return end
        local keep = {}
        local count = 0
        for _, e in ipairs(_entries) do
            if e.file == file then
                count = count + 1
            else
                table.insert(keep, e)
            end
        end
        _entries = keep
        _persist()
        _refresh_signs()
        if count > 0 then
            vim.notify(string.format("[keystone] Cleared %d bookmark(s) from file", count))
        end
    end)
end

function M.clear_all()
    if #_entries == 0 then
        vim.notify("[keystone] No bookmarks to clear")
        return
    end
    _uitool.confirm_action("Clear all bookmarks", false, function(accepted)
        if not accepted then return end
        _entries = {}
        _persist()
        _refresh_signs()
        vim.notify("[keystone] All bookmarks cleared")
    end)
end

---@return keystone.bookmarks.Entry[]
function M.get_entries()
    return vim.deepcopy(_entries)
end

function M.pick()
    if #_entries == 0 then
        vim.notify("[keystone] No bookmarks set", vim.log.levels.WARN)
        return
    end

    local cur_file, cur_lnum = _uitool.get_current_file_and_line()
    if cur_file then cur_file = _norm(cur_file) end

    local entries = vim.deepcopy(_entries)
    table.sort(entries, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.lnum < b.lnum
    end)

    _picker.open({
        prompt        = "Bookmarks",
        enable_preview = true,
        finder        = function(query, _, _fetch_opts, callback)
            local items = {}
            for _, entry in ipairs(entries) do
                local match = _pickertools.match_label(entry.name, query)
                if match then
                    local relpath = vim.fn.fnamemodify(entry.file, ":~:.")
                    local loc_chunk = { "  " .. relpath .. ":" .. entry.lnum, "Comment" }
                    table.insert(match.chunks, loc_chunk)
                    ---@type keystone.Picker.Item
                    local item = {
                        label_chunks = match.chunks,
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
            _uitool.smart_open_file(data.filepath, data.lnum, data.col)
        end
    end)
end

---@param opts keystone.bookmarks.Config?
function M.setup(opts)
    _config    = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
    M.config   = _config

    if not _config.enabled then return end

    vim.fn.sign_define(_SIGN_NAME, {
        text   = _config.sign_text,
        texthl = _config.sign_hl,
    })

    _entries = _store.load(_config)

    local _augroup = vim.api.nvim_create_augroup("keystone_bookmarks", { clear = true })
    vim.api.nvim_create_autocmd("BufReadPost", {
        group    = _augroup,
        callback = function() _refresh_signs() end,
    })

    _refresh_signs()

    require("keystone.util.usercmd").register_user_cmd("Bookmarks",
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
