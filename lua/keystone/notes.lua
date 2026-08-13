local M    = {}

---@class keystone.notes.Config
---@field enabled boolean
---@field persist_path (string | fun():string)?  -- notes file path; nil = ~/.nvimnotes
---@field sign_text string
---@field sign_hl string

---@class keystone.notes.Note
---@field id integer?     -- identity within the session; absent on a freshly parsed line
---@field label string    -- the note text; the note's reason for existing
---@field file string?    -- absolute path, when the note is anchored to a location
---@field lnum integer?   -- 1-based line number, set together with `file`

-- Startup-time state (notes, extmark group, autocmds) lives in `keystone.notes.core`.
-- Interactive commands live in `keystone.notes.actions`, which pulls in the heavy UI
-- modules and is required only the first time a command runs -- keeping `setup` cheap.
local core = require("keystone.notes.core")

---@return keystone.notes.actions
local function _actions()
    return require("keystone.notes.actions")
end

M.config = core.default_config()

----------- PUBLIC API -----------

--- Write a note anchored to the current line. Prompts for the text, starting from
--- the note already on that line if there is one (which it then replaces).
function M.add_at_cursor()
    _actions().add_at_cursor()
end

--- Write a note with no location at all.
function M.add_free()
    _actions().add_free()
end

function M.delete_at_cursor()
    local file, lnum = core.get_cur_loc()
    if not file or not lnum then return end
    local note = core.note_at(file, lnum)
    if note then core.remove(note.id) end
    core.refresh_list()
end

function M.clear_file()
    _actions().clear_file()
end

function M.clear_all()
    _actions().clear_all()
end

---@return keystone.notes.Note[]
function M.get_notes()
    return core.read_notes()
end

function M.pick()
    _actions().pick()
end

function M.open_list()
    _actions().open_list()
end

----------- COMMAND -----------

local _subcommand_list = { "add", "add_free", "delete", "pick", "list", "clear_file", "clear_all" }

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
    local cmd = args[1] or "add"
    if cmd == "add" then
        M.add_at_cursor()
    elseif cmd == "add_free" then
        M.add_free()
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
        vim.notify("[keystone] Unknown Note subcommand: " .. tostring(cmd), vim.log.levels.WARN)
    end
end

---@param opts keystone.notes.Config?
function M.setup(opts)
    local config = vim.tbl_deep_extend("force", core.default_config(), opts or {})
    M.config = config

    if not config.enabled then return end

    core.init(config)

    -- Distinct from the "keystone_notes" augroup the extmark group registers its
    -- Buf* handlers under (see extmarks.define_group): reusing that name with clear=true
    -- would wipe the BufReadPost handler that applies signs to later-loaded buffers.
    local augroup = vim.api.nvim_create_augroup("keystone_notes_setup", { clear = true })
    -- During a session the in-memory notes are the single source of truth and disk is
    -- left untouched; the one write to the notes file happens here, on exit.
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group    = augroup,
        callback = function() core.save_to_disk() end,
    })

    vim.api.nvim_create_user_command("Note", function(cmd_opts)
        require("keystone.util.usercmd").handle(cmd_opts, _run_command)
    end, {
        nargs = "*",
        desc = "Persistent notes, optionally anchored to a line",
        complete = function(arg_lead, cmd_line, _)
            return require("keystone.util.usercmd").complete(arg_lead, cmd_line, _get_subcommands)
        end,
    })

    -- `:Note pick` needs no plugin, but the note list is also a natural picker
    -- source; offer it to the optional ezpick.nvim when that is installed, which is
    -- where the richer view (location on a virtual line, file preview) lives. The
    -- `pcall` is unavoidable: "is this plugin installed?" has no non-throwing form.
    local ok, ezpick = pcall(require, "ezpick")
    if ok then
        ezpick.register("notes", function()
            return require("keystone.notes.picker").spec()
        end)
    end
end

return M
