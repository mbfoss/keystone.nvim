---@brief The filetree options. A leaf module, so the window and tree code can
---read the live config without requiring `keystone.filetree` itself.

local cfgutil = require("keystone.util.config")

local M = {}

---@class keystone.filetree.Config
---@field width_ratio number?   fraction of the editor width the window takes (left/right)
---@field height_ratio number?  fraction of the editor height the window takes (top/bottom)
---@field position "top"|"bottom"|"left"|"right"?  side the window opens on
---@field follow_current_buffer boolean?

---@type keystone.filetree.Config
local _defaults = {
    width_ratio = 0.2,
    height_ratio = 0.3,
    position = "left",
    follow_current_buffer = false,
}

---The live options. Always this same table, so it is safe to capture at a
---module's top.
---@type keystone.filetree.Config
M.current = vim.deepcopy(_defaults)

---A fresh copy of the defaults, as `apply()` starts from. Safe to mutate.
---@return keystone.filetree.Config
function M.defaults()
    return vim.deepcopy(_defaults)
end

---@param opts table?
function M.apply(opts)
    cfgutil.apply(M.current, _defaults, opts)
end

return M
