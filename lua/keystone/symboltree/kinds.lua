local M = {}

--- LSP `SymbolKind` (1..26) metadata: display name, icon and highlight group.
--- Indexed by the numeric kind straight off the wire.
---@class keystone.symboltree.Kind
---@field name string
---@field icon string
---@field hl string

---@type table<integer, keystone.symboltree.Kind>
M.kinds = {
    [1]  = { name = "File",          icon = "󰈙", hl = "Directory" },
    [2]  = { name = "Module",        icon = "󰆧", hl = "Include" },
    [3]  = { name = "Namespace",     icon = "󰌗", hl = "Include" },
    [4]  = { name = "Package",       icon = "󰏗", hl = "Include" },
    [5]  = { name = "Class",         icon = "󰌗", hl = "Type" },
    [6]  = { name = "Method",        icon = "󰆧", hl = "Function" },
    [7]  = { name = "Property",      icon = "󰜢", hl = "Identifier" },
    [8]  = { name = "Field",         icon = "󰇽", hl = "Identifier" },
    [9]  = { name = "Constructor",   icon = "", hl = "Function" },
    [10] = { name = "Enum",          icon = "󰕘", hl = "Type" },
    [11] = { name = "Interface",     icon = "", hl = "Type" },
    [12] = { name = "Function",      icon = "󰊕", hl = "Function" },
    [13] = { name = "Variable",      icon = "󰀫", hl = "Identifier" },
    [14] = { name = "Constant",      icon = "󰏿", hl = "Constant" },
    [15] = { name = "String",        icon = "󰀬", hl = "String" },
    [16] = { name = "Number",        icon = "󰎠", hl = "Number" },
    [17] = { name = "Boolean",       icon = "◩", hl = "Boolean" },
    [18] = { name = "Array",         icon = "󰅪", hl = "Type" },
    [19] = { name = "Object",        icon = "󰅩", hl = "Type" },
    [20] = { name = "Key",           icon = "󰌋", hl = "Identifier" },
    [21] = { name = "Null",          icon = "󰟢", hl = "Constant" },
    [22] = { name = "EnumMember",    icon = "󰕘", hl = "Constant" },
    [23] = { name = "Struct",        icon = "󰙅", hl = "Type" },
    [24] = { name = "Event",         icon = "", hl = "Type" },
    [25] = { name = "Operator",      icon = "󰆕", hl = "Operator" },
    [26] = { name = "TypeParameter", icon = "󰆕", hl = "Type" },
}

---@type keystone.symboltree.Kind
local _UNKNOWN = { name = "Unknown", icon = "󰠱", hl = "Normal" }

---@param kind integer?
---@return keystone.symboltree.Kind
function M.get(kind)
    return M.kinds[kind] or _UNKNOWN
end

return M
