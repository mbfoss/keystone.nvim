---@brief The calltree options. A leaf module, so the window and tree code can
---read the live config without requiring `keystone.calltree` itself.

local cfgutil = require("keystone.util.config")

local M = {}

---@class keystone.calltree.Config
---@field width_ratio number?   fraction of the editor width the window takes (left/right)
---@field height_ratio number?  fraction of the editor height the window takes (top/bottom)
---@field position "top"|"bottom"|"left"|"right"?  side the window opens on
---@field direction keystone.calltree.Direction?  which way to walk by default
---@field show_detail boolean?  show the server-provided detail text
---@field auto_expand_root boolean?  expand the root as soon as it resolves

---@type keystone.calltree.Config
local _defaults = {
    width_ratio      = 0.2,
    height_ratio     = 0.2,
    position         = "bottom",
    direction        = "incoming",
    show_detail      = true,
    auto_expand_root = true,
}

---The live options. Always this same table, so it is safe to capture at a
---module's top.
---@type keystone.calltree.Config
M.current = vim.deepcopy(_defaults)

---A fresh copy of the defaults, as `apply()` starts from. Safe to mutate.
---@return keystone.calltree.Config
function M.defaults()
    return vim.deepcopy(_defaults)
end

---@param opts table?
function M.apply(opts)
    cfgutil.apply(M.current, _defaults, opts)
end

return M
