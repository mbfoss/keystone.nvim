--- Keymap hints, in the style of which-key / mini.clue.
---
--- A configured set of *trigger* keys (e.g. `<leader>`, `g`, `z`, `<C-w>`) is
--- mapped with `nowait`. When one is pressed, the engine reads the following
--- keys itself (`getcharstr`) and shows a floating window listing the keys that
--- may follow; pressing further keys narrows the list. The resolved sequence is
--- then re-fed to Neovim so the real mapping (or built-in) runs natively — with
--- counts, registers, operators and dot-repeat intact (see `keystone.clue.engine`).
--- Because the engine reads keys itself, a sequence resolves whether typed
--- quickly or slowly.
local engine = require("keystone.clue.engine")
local window = require("keystone.clue.window")
local keys = require("keystone.clue.keys")
local usercmd = require("keystone.util.usercmd")

local M = {}

--- A single key that may start a clue interaction. Must be one key (e.g.
--- `<leader>`, `g`, `<C-w>`).
---@class keystone.clue.Trigger
---@field mode string single-mode short name (`"n"`, `"x"`)
---@field keys string the trigger key, `<leader>` etc. allowed

---@class keystone.clue.WinConfig
---@field border           string|string[]
---@field separator        string text between a key and its description
---@field width_ratio      number max window width as a fraction of the editor
---@field max_height_ratio number max window height as a fraction of the editor
---@field title            boolean show the pressed-keys title
---@field delay            integer ms to wait before showing (so fast sequences don't flash)

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
            -- operator + selector, so `ciw`, `da"`, `yi(` … list their text
            -- objects directly (no intermediate inner/around menu), mirroring the
            -- Visual-mode `i`/`a` triggers below. Triggering on the two-key `ci`
            -- (not bare `c`) leaves `cw`, `cc`, `cf{char}` … native.
            { mode = "n", keys = "ci" },
            { mode = "n", keys = "ca" },
            { mode = "n", keys = "di" },
            { mode = "n", keys = "da" },
            { mode = "n", keys = "yi" },
            { mode = "n", keys = "ya" },
            { mode = "x", keys = "<leader>" },
            { mode = "x", keys = "<localleader>" },
            { mode = "x", keys = "g" },
            { mode = "x", keys = "z" },
            -- text-object selectors in Visual mode (covers `vi(`, `va"` … too)
            { mode = "x", keys = "i" },
            { mode = "x", keys = "a" },
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
            delay = 200,
        },
    }
end

---@type keystone.clue.Config
M.config = _get_defaults()

local _enabled = false
local _initialized = false

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

--- One-time, config-independent initialization (highlight groups + `:Clue`
--- command). Idempotent, so calling `enable()` without `setup()` still works.
local function _ensure_initialized()
    if _initialized then
        return
    end
    _initialized = true

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
            error("keystone.clue: unknown subcommand: " .. tostring(sub))
        end
    end, {
        desc = "keystone clue",
        subcommand_fn = function()
            return { "enable", "disable", "toggle" }
        end,
    })
end

function M.enable()
    if _enabled then
        return
    end
    _enabled = true
    _ensure_initialized()
    -- `setup()` normalizes groups; populate it here too so a bare `enable()`
    -- with the default config still renders group labels.
    M.config._groups = M.config._groups or _normalize_groups(M.config.groups)
    engine.enable(M.config)
end

function M.disable()
    if not _enabled then
        return
    end
    _enabled = false
    engine.disable()
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

    _ensure_initialized()

    -- re-enable from scratch so a fresh config takes effect
    if _enabled then
        M.disable()
    end
    if M.config.enabled then
        M.enable()
    end
end

return M
