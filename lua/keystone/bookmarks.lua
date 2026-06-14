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

local _SIGN_NAME = "bookmark"

local store      = require("keystone.bookmarks.store")
local inputwin   = require("keystone.util.inputwin")
local uitool     = require("keystone.util.uitool")
local picker     = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")

---@type keystone.bookmarks.signs.Group
local _sign_group

---@type keystone.bookmarks.Config
local _config

local _next_id = 0

local function _new_id()
    _next_id = _next_id + 1
    return _next_id
end

local function _get_default_config()
    ---@type keystone.bookmarks.Config
    return {
        enabled    = true,
        persist_dir = nil,
        sign_text  = "*",
        sign_hl    = "DiagnosticInfo",
    }
end

M.config = _get_default_config()

local function _norm(file)
    if not file or file == "" then return file end
    return vim.fn.fnamemodify(file, ":p")
end

---@return keystone.bookmarks.Entry[]
local function _read_entries()
    local signs = _sign_group.get_signs(true)
    local entries = {}
    for _, s in ipairs(signs) do
        entries[#entries + 1] = {
            name = s.user_data.name,
            file = s.file,
            lnum = s.lnum,
        }
    end
    return entries
end

local function _persist()
    store.save(_config)
end

---@param name string
---@return keystone.bookmarks.signs.SignInfo?
local function _find_by_name(name)
    for _, s in ipairs(_sign_group.get_signs(false)) do
        if s.user_data.name == name then return s end
    end
end

---@param name string
---@param file string
---@param lnum integer
local function _upsert(name, file, lnum)
    local by_loc = _sign_group.get_sign_by_location(file, lnum, true)
    if by_loc then
        store.delete(file, lnum)
        _sign_group.remove_sign(by_loc.id)
    end

    store.add({ name = name, file = file, lnum = lnum })
    _sign_group.set_file_sign(_new_id(), file, lnum, _SIGN_NAME, { name = name })
    _persist()
end

----------- PUBLIC API -----------

function M.set_at_cursor()
    local file, lnum = uitool.get_current_file_and_line()
    if not file or not lnum then
        vim.notify("[keystone] No valid file at cursor", vim.log.levels.WARN)
        return
    end
    file = _norm(file)
    local existing = _sign_group.get_sign_by_location(file, lnum, true)
    local default = existing and existing.user_data.name or ""
    inputwin.open({ prompt = "Bookmark", default = default }, function(name)
        if not name or name:match("^%s*$") then return end
        name = name:match("^%s*(.-)%s*$")
        _upsert(name, file, lnum)
    end)
end

function M.delete_at_cursor()
    local file, lnum = uitool.get_current_file_and_line()
    if not file or not lnum then return end
    file = _norm(file)
    local sign = _sign_group.get_sign_by_location(file, lnum, true)
    if not sign then
        vim.notify("[keystone] No bookmark at current line", vim.log.levels.WARN)
        return
    end
    local name = sign.user_data.name
    store.delete(file, lnum)
    _sign_group.remove_sign(sign.id)
    _persist()
    vim.notify("[keystone] Deleted bookmark: " .. name)
end

function M.clear_file()
    local buf = vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local file = _norm(vim.api.nvim_buf_get_name(buf))
    if not file or file == "" then return end
    uitool.confirm_action("Clear bookmarks in current file", false, function(accepted)
        if not accepted then return end
        local signs = _sign_group.get_file_signs(file, false)
        local before = #signs
        for _, s in ipairs(signs) do store.delete(s.file, s.lnum) end
        _sign_group.remove_file_signs(file)
        _persist()
        if before > 0 then
            vim.notify(string.format("[keystone] Cleared %d bookmark(s) from file", before))
        end
    end)
end

function M.clear_all()
    if #_sign_group.get_signs(false) == 0 then
        vim.notify("[keystone] No bookmarks to clear")
        return
    end
    uitool.confirm_action("Clear all bookmarks", false, function(accepted)
        if not accepted then return end
        for _, s in ipairs(_sign_group.get_signs(false)) do store.delete(s.file, s.lnum) end
        _sign_group.remove_signs()
        _persist()
        vim.notify("[keystone] All bookmarks cleared")
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

    local cur_file, cur_lnum = uitool.get_current_file_and_line()
    if cur_file then cur_file = _norm(cur_file) end

    table.sort(entries, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.lnum < b.lnum
    end)

    picker.open({
        prompt        = "Bookmark",
        enable_preview = true,
        finder        = function(query, _, _fetch_opts, callback)
            local items = {}
            for _, entry in ipairs(entries) do
                local match = pickertools.match_label(entry.name, query)
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
            uitool.smart_open_file(data.filepath, data.lnum, data.col)
        end
    end)
end

---@param opts keystone.bookmarks.Config?
function M.setup(opts)
    _config  = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
    M.config = _config

    if not _config.enabled then return end

    _sign_group = require("keystone.bookmarks.signs").define_group("bookmarks", { priority = 20 })
    _sign_group.define_sign(_SIGN_NAME, _config.sign_text, _config.sign_hl)

    local stored = store.load(_config)
    for _, e in ipairs(stored) do
        _sign_group.set_file_sign(_new_id(), e.file, e.lnum, _SIGN_NAME, { name = e.name })
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
