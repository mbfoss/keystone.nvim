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
    file = _norm(file)
    local mark = _mark_group.get_extmark_by_location(file, lnum, true)
    if not mark then
        return
    end
    local name = mark.user_data.name
    store.delete(file, lnum)
    _mark_group.remove_extmark(mark.id)
    _persist()
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
        prompt          = "Bookmark",
        enable_preview  = true,
        enable_list_sep = true,
        finder          = function(query, _, _fetch_opts, callback)
            local items = {}
            for _, entry in ipairs(entries) do
                local match = pickertools.match_label(entry.name, query)
                if match then
                    local relpath = vim.fn.fnamemodify(entry.file, ":~:.")
                    local loc_chunk = {relpath .. ":" .. entry.lnum, "@namspace" }
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
