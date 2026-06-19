--- Keymap hints, in the style of which-key / mini.clue.
---
--- A configured set of *trigger* keys (e.g. `<leader>`, `g`, `z`, `<C-w>`) are
--- watched via `vim.on_key`. When one is pressed, a floating window lists the
--- keys that may follow and their descriptions; pressing further keys narrows
--- the list. The observer is passive — Neovim resolves and executes every key
--- itself, so counts, registers, operators and mappings all behave normally.
local keys = require("keystone.clue.keys")
local window = require("keystone.clue.window")
local observer = require("keystone.clue.observer")
local usercmd = require("keystone.util.usercmd")

local M = {}

--- A single key that, once pressed, may start a clue interaction. Triggers must
--- be a single key (e.g. `<leader>`, `g`, `<C-w>`).
---@class keystone.clue.Trigger
---@field mode string single-mode short name (`"n"`, `"x"`)
---@field keys string the trigger key, `<leader>` etc. allowed

---@class keystone.clue.WinConfig
---@field border          string|string[]
---@field separator       string text between a key and its description
---@field width_ratio     number max window width as a fraction of the editor
---@field max_height_ratio number max window height as a fraction of the editor
---@field title           boolean show the pressed-keys title

---@class keystone.clue.Config
---@field enabled       boolean
---@field triggers      keystone.clue.Trigger[]
---@field groups        table<string, string> prefix (e.g. `"<leader>f"`) -> group label
---@field clues         keystone.clue.Clue[] extra virtual entries for un-mapped keys
---@field builtin_clues boolean include built-in `<C-w>`/`z`/`g` hints
---@field win           keystone.clue.WinConfig
---@field _groups       table<string, string>? normalized `groups`, internal

---@return keystone.clue.Config
local function _get_defaults()
    return {
        enabled = true,
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
        clues = {},
        builtin_clues = true,
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

function M.enable()
    if _enabled then
        return
    end
    _enabled = true
    observer.config = M.config
    observer.enable()
end

function M.disable()
    if not _enabled then
        return
    end
    _enabled = false
    observer.disable()
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
    observer.config = M.config

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

    -- re-enable from scratch so a fresh config takes effect
    if _enabled then
        observer.disable()
        _enabled = false
    end
    if M.config.enabled then
        M.enable()
    end
end

return M
