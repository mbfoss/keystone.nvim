---@brief The clue options. A leaf module, so the engine can read the live
---config without requiring `keystone.clue` itself.

local cfgutil = require("keystone.util.config")

local M = {}

---@class keystone.clue.Config
---@field delay integer                                ms to wait before the popup appears
---@field border string|string[]                       float border style
---@field max_desc_width integer                       max display width of a hint's description (cropped with …)
---@field preset boolean                               register builtin g/z/window descriptions
---@field builtin { marks: boolean, registers: boolean } enable dynamic generators
---@field triggers keystone.clue.Trigger[]             keys that open the clue popup

---@type keystone.clue.Config
local _defaults = {
    delay = 300,
    border = "rounded",
    max_desc_width = 40,
    preset = true,
    builtin = { marks = true, registers = true },
    triggers = {
        { mode = "n", keys = "<leader>" },
        { mode = "x", keys = "<leader>" },
        { mode = "n", keys = "g" },
        { mode = "x", keys = "g" },
        { mode = "n", keys = "z" },
        { mode = "x", keys = "z" },
        { mode = "n", keys = "'" },
        { mode = "n", keys = "`" },
        { mode = "x", keys = "'" },
        { mode = "x", keys = "`" },
        { mode = "n", keys = '"' },
        { mode = "x", keys = '"' },
        { mode = "n", keys = "]" },
        { mode = "n", keys = "[" },
        { mode = "n", keys = "<C-w>" },
        { mode = "i", keys = "<C-x>" },
        { mode = "i", keys = "<C-r>" },
        { mode = "c", keys = "<C-r>" },
    },
}

---The live options. Always this same table, so it is safe to capture at a
---module's top.
---@type keystone.clue.Config
M.current = vim.deepcopy(_defaults)

---A fresh copy of the defaults, as `apply()` starts from. Safe to mutate.
---@return keystone.clue.Config
function M.defaults()
    return vim.deepcopy(_defaults)
end

---@param opts table?
function M.apply(opts)
    cfgutil.apply(M.current, _defaults, opts)
    -- `triggers` is an array, so it must replace wholesale rather than merge by
    -- index. `builtin` is a dict and is correctly handled by the deep merge above
    -- (a partial `{ marks = false }` must keep the default `registers = true`).
    if opts and opts.triggers then
        M.current.triggers = vim.deepcopy(opts.triggers)
    end
end

return M
