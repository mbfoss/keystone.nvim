--- Keymap hints, in the style of which-key / mini.clue.
---
--- A configured set of *trigger* keys (e.g. `<leader>`, `g`, `z`, `<C-w>`) are
--- mapped so that pressing one opens a floating window listing the keys that
--- may follow, along with their descriptions. Pressing further keys narrows the
--- list until the sequence resolves to a mapping (which is then executed) or to
--- a built-in command (which is replayed as typed).
local keys = require("keystone.clue.keys")
local window = require("keystone.clue.window")
local runner = require("keystone.clue.runner")
local usercmd = require("keystone.util.usercmd")

local M = {}

--- A key sequence that, once pressed, starts a clue interaction.
---@class keystone.clue.Trigger
---@field mode string single-mode short name (`"n"`, `"x"`, ...)
---@field keys string left-hand side, `<leader>` etc. allowed

---@class keystone.clue.WinConfig
---@field border          string|string[]
---@field separator       string text between a key and its description
---@field width_ratio     number max window width as a fraction of the editor
---@field max_height_ratio number max window height as a fraction of the editor
---@field title           boolean show the pressed-keys title

---@class keystone.clue.Config
---@field enabled  boolean
---@field delay    integer ms to wait before the window appears (0 = immediate)
---@field triggers keystone.clue.Trigger[]
---@field groups   table<string, string> prefix (e.g. `"<leader>f"`) -> group label
---@field win      keystone.clue.WinConfig
---@field _groups  table<string, string>? normalized `groups`, internal

---@return keystone.clue.Config
local function _get_defaults()
    return {
        enabled = true,
        delay = 200,
        triggers = {
            { mode = "n", keys = "<leader>" },
            { mode = "n", keys = "<localleader>" },
            { mode = "n", keys = "g" },
            { mode = "n", keys = "z" },
            { mode = "n", keys = "[" },
            { mode = "n", keys = "]" },
            { mode = "n", keys = "<C-w>" },
            { mode = "x", keys = "<leader>" },
            { mode = "x", keys = "<localleader>" },
            { mode = "x", keys = "g" },
            { mode = "x", keys = "z" },
        },
        groups = {},
        win = {
            border = "rounded",
            separator = "  ",
            width_ratio = 0.9,
            max_height_ratio = 0.4,
            title = true,
        },
    }
end

---@type keystone.clue.Config
M.config = _get_defaults()

local _enabled = false

---@type keystone.clue.Trigger[]
local _registered = {}

--- Pre-tokenize the configured group prefixes so the renderer can look them up
--- by token-join (see `keys.clues`).
---@param groups table<string, string>
---@return table<string, string>
local function _normalize_groups(groups)
    local out = {}
    for prefix, label in pairs(groups or {}) do
        out[table.concat(keys.tokenize(keys.to_raw(prefix)))] = label
    end
    return out
end

local function _clear_triggers()
    for _, t in ipairs(_registered) do
        pcall(vim.keymap.del, t.mode, t.keys)
    end
    _registered = {}
end

local function _set_triggers()
    _clear_triggers()
    for _, t in ipairs(M.config.triggers) do
        local mode = t.mode or "n"
        local lhs = t.keys
        vim.keymap.set(mode, lhs, function()
            runner.run(mode, lhs)
        end, { desc = keys.TRIGGER_DESC, silent = true })
        table.insert(_registered, { mode = mode, keys = lhs })
    end
end

function M.enable()
    if _enabled then
        return
    end
    _enabled = true
    runner.config = M.config
    _set_triggers()
end

function M.disable()
    if not _enabled then
        return
    end
    _enabled = false
    _clear_triggers()
end

function M.toggle()
    if _enabled then
        M.disable()
    else
        M.enable()
    end
end

---@param opts keystone.clue.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_defaults(), opts or {})
    M.config._groups = _normalize_groups(M.config.groups)
    runner.config = M.config

    window.setup_hl()

    usercmd.register_user_cmd("Clue", function(_, args)
        local sub = args[1] or "toggle"
        if sub == "enable" then
            M.enable()
        elseif sub == "disable" then
            M.disable()
        elseif sub == "toggle" then
            M.toggle()
        else
            error("unknown subcommand: " .. tostring(sub))
        end
    end, {
        desc = "keystone clue",
        subcommand_fn = function()
            return { "enable", "disable", "toggle" }
        end,
    })

    if M.config.enabled then
        -- triggers were cleared by a previous enable() only if _enabled; ensure
        -- a fresh registration reflecting the new config.
        _enabled = false
        M.enable()
    else
        M.disable()
    end
end

return M
