local M = {}

---@class keystone.clue.Config
---@field delay integer                                ms to wait before the popup appears
---@field border string|string[]                       float border style
---@field preset boolean                               register builtin g/z/window descriptions
---@field builtin { marks: boolean, registers: boolean } enable dynamic generators
---@field triggers keystone.clue.Trigger[]             keys that open the clue popup

---@return keystone.clue.Config
function M.defaults()
    return {
        delay = 300,
        border = "rounded",
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
            { mode = "n", keys = "<C-w>" },
            { mode = "i", keys = "<C-x>" },
            { mode = "i", keys = "<C-r>" },
            { mode = "c", keys = "<C-r>" },
        },
    }
end

return M
