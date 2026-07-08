local M    = {}

---@class keystone.bookmarks.Config
---@field enabled boolean
---@field persist_path (string | fun():string)?  -- bookmarks file path; nil = ~/.nvimbookmarks
---@field sign_text string
---@field sign_hl string

---@class keystone.bookmarks.Entry
---@field file string    -- absolute path
---@field lnum integer   -- 1-based line number
---@field label string?  -- optional user-facing label

-- Startup-time state (store, extmark group, autocmds) lives in
-- `keystone.bookmarks.core`. The interactive commands live in
-- `keystone.bookmarks.actions`, which pulls in the heavy UI modules and is only
-- required the first time a command runs -- keeping `setup` cheap.
local core = require("keystone.bookmarks.core")

---@return keystone.bookmarks.actions
local function _actions()
    return require("keystone.bookmarks.actions")
end

M.config = core.default_config()

----------- PUBLIC API -----------

function M.set_at_cursor()
    local file, lnum = core.get_cur_loc()
    if not file or not lnum then
        vim.notify("[keystone] No valid file at cursor", vim.log.levels.WARN)
        return
    end
    file = core.norm(file)
    if core.mark_group.get_extmark_by_location(file, lnum, true) then return end
    core.upsert(file, lnum, nil)
end

function M.set_label_at_cursor()
    _actions().set_label_at_cursor()
end

function M.delete_at_cursor()
    local file, lnum = core.get_cur_loc()
    if not file or not lnum then return end
    core.delete_loc(core.norm(file), lnum)
end

function M.clear_file()
    _actions().clear_file()
end

function M.clear_all()
    _actions().clear_all()
end

---@return keystone.bookmarks.Entry[]
function M.get_entries()
    return core.read_entries()
end

function M.pick()
    _actions().pick()
end

function M.open_list()
    _actions().open_list()
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
    local config = vim.tbl_deep_extend("force", core.default_config(), opts or {})
    M.config = config

    if not config.enabled then return end

    core.init(config)

    -- Distinct from the "keystone_bookmarks" augroup that the extmark group
    -- registers its Buf* handlers under (see extmarks.define_group): reusing that
    -- name with clear = true would wipe the BufReadPost handler that applies signs
    -- to buffers loaded after setup, so startup files would show no signs.
    local augroup = vim.api.nvim_create_augroup("keystone_bookmarks_setup", { clear = true })
    vim.api.nvim_create_autocmd("VimLeave", {
        group    = augroup,
        callback = core.persist,
    })
    -- Writing the bookmarks file makes its content authoritative for the signs.
    vim.api.nvim_create_autocmd("BufWritePost", {
        group    = augroup,
        pattern  = core.store_filepath(),
        callback = core.sync_from_file,
    })

    require("keystone.tk.usercmd").register_user_cmd("Bookmark", _run_command, {
        desc          = "Persistent line bookmarks",
        subcommand_fn = _get_subcommands,
    })
end

return M
