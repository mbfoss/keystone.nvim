local M    = {}

---@class keystone.notes.Config
---@field enabled boolean
---@field persist_path (string | fun():string)?  -- notes file path; nil = ~/.nvimnotes

---@class keystone.notes.Note
---@field label string    -- the note text, exactly as the line reads
---@field file string?    -- absolute path, when the note is anchored to a location
---@field lnum integer?   -- 1-based line number, when the reference names one

---@class keystone.notes.Ref
---@field start integer   -- 1-based byte index of the `@`
---@field stop integer    -- 1-based byte index of the reference's last byte
---@field path string     -- the path exactly as written
---@field file string     -- that path resolved to an absolute one
---@field lnum integer?   -- 1-based line number, when the reference names one

-- Parsing and the notes file itself live in `keystone.notes.core`.
-- Interactive commands live in `keystone.notes.actions`, which pulls in the heavy UI
-- modules and is required only the first time a command runs -- keeping `setup` cheap.
local core = require("keystone.notes.core")

---@return keystone.notes.actions
local function _actions()
    return require("keystone.notes.actions")
end

M.config = core.default_config()

----------- PUBLIC API -----------

--- Write a note anchored to the current line. Opens the notes list with a new line
--- started, its `@` reference already filled in, and the cursor in it.
function M.add_at_cursor()
    _actions().add_at_cursor()
end

--- Write a note with no location at all: the notes list opens with an empty line
--- started and the cursor in it.
function M.add_free()
    _actions().add_free()
end

--- The notes currently in the file, in the order they are written there.
---@return keystone.notes.Note[]
function M.get_notes()
    return core.read_notes()
end

function M.open_list()
    _actions().open_list()
end

----------- COMMAND -----------

local _subcommand_list = { "list", "add", "add_free" }

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
    local cmd = args[1] or "list"
    if cmd == "add" then
        M.add_at_cursor()
    elseif cmd == "add_free" then
        M.add_free()
    elseif cmd == "list" then
        M.open_list()
    else
        vim.notify("[keystone] Unknown Notes subcommand: " .. tostring(cmd), vim.log.levels.WARN)
    end
end

---@param opts keystone.notes.Config?
function M.setup(opts)
    local config = vim.tbl_deep_extend("force", core.default_config(), opts or {})
    M.config = config

    if not config.enabled then return end

    core.init(config)

    vim.api.nvim_create_user_command("Notes", function(cmd_opts)
        require("keystone.util.usercmd").handle(cmd_opts, _run_command)
    end, {
        nargs = "*",
        desc = "Persistent notes, optionally anchored to a line",
        complete = function(arg_lead, cmd_line, _)
            return require("keystone.util.usercmd").complete(arg_lead, cmd_line, _get_subcommands)
        end,
    })
end

return M
