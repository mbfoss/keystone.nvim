--- keystone.clue — a which-key style popup of follow-up keys.
---
--- Each configured trigger (`<leader>`, `g`, `z`, marks, registers, ...) is a
--- `nowait` keymap. When pressed, the engine reads the next keys, shows a popup
--- of the available continuations after a short delay, then re-feeds the resolved
--- sequence so the real mapping runs natively. Group labels come from `add()`.
local Keys = require("keystone.clue.keys")

local M = {}

---@class keystone.clue.Trigger
---@field mode string  single-letter mode (n/x/v/i/c/o/...)
---@field keys string  raw lhs, e.g. "<leader>" or "g"

---@class keystone.clue.Clue
---@field keys string   normalised key sequence
---@field desc? string  display description
---@field group? boolean

---@type keystone.clue.Config
M.config = require("keystone.clue.config").defaults()

---@type table<string, keystone.clue.Clue[]>
M._clues = {}

---@type table<string, { keys: string, expand: fun(): keystone.clue.Item[] }[]>
M._builtins = {}

---@param mode string mapmode
---@return keystone.clue.Clue[]
function M.get_clues(mode)
    return M._clues[mode] or {}
end

---@param mode string mapmode
---@return { keys: string, expand: fun(): keystone.clue.Item[] }[]
function M.get_builtins(mode)
    return M._builtins[mode] or {}
end

--- Register group labels / descriptions (and optionally create mappings). Spec
--- entries mirror which-key:
---   { "<leader>f", group = "+Find", mode = { "n" } }   -- prefix label
---   { "<leader>x", desc = "Save",   mode = { "n" } }    -- label an existing map
---   { "<leader>q", ":q<cr>", desc = "Quit" }            -- also create the map
---@param specs table[]
function M.add(specs)
    for _, spec in ipairs(specs) do
        local lhs = spec[1] or spec.keys
        if type(lhs) == "string" then
            local modes = spec.mode or { "n" }
            if type(modes) == "string" then
                modes = vim.split(modes, "")
            end
            local is_group = spec.group ~= nil and spec.group ~= false
            local desc = spec.desc or (type(spec.group) == "string" and spec.group) or nil

            local norm = Keys.norm(lhs)
            for _, mode in ipairs(modes) do
                local mm = Keys.spec_mode(mode)
                M._clues[mm] = M._clues[mm] or {}
                table.insert(M._clues[mm], { keys = norm, desc = desc, group = is_group })
            end

            local rhs = spec[2]
            if rhs ~= nil then
                vim.keymap.set(spec.mode or "n", lhs, rhs, {
                    desc = type(desc) == "string" and desc or nil,
                    silent = spec.silent ~= false,
                })
            end
        end
    end
end

---@param config keystone.clue.Config
local function _load_builtins(config)
    M._builtins = {}
    local builtin = require("keystone.clue.builtin")
    for _, b in ipairs(builtin.generators(config.builtin)) do
        local mm = Keys.spec_mode(b.mode)
        M._builtins[mm] = M._builtins[mm] or {}
        table.insert(M._builtins[mm], { keys = Keys.norm(b.keys), expand = b.expand })
    end
    if config.preset then
        M.add(builtin.preset_clues())
    end
end

---@param opts table?
function M.setup(opts)
    opts = opts or {}
    M.config = vim.tbl_deep_extend("force", require("keystone.clue.config").defaults(), opts)
    -- `triggers` is an array, so it must replace wholesale rather than merge by
    -- index. `builtin` is a dict and is correctly handled by the deep merge above
    -- (a partial `{ marks = false }` must keep the default `registers = true`).
    if opts.triggers then
        M.config.triggers = opts.triggers
    end

    M._clues = {}
    require("keystone.clue.view").setup_hl()
    require("keystone.clue.view").border = M.config.border
    _load_builtins(M.config)
    require("keystone.clue.engine").register_triggers(M.config.triggers)
end

return M
