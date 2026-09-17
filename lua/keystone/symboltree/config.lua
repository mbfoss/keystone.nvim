---@brief The symboltree options. A leaf module, so the window and tree code can
---read the live config without requiring `keystone.symboltree` itself.

local cfgutil = require("keystone.util.config")

local M = {}

---@class keystone.symboltree.Config
---@field width_ratio number?
---@field track_cursor boolean?  highlight/follow the symbol under the cursor
---@field auto_expand boolean?   expand every symbol on load
---@field show_detail boolean?   show the server-provided detail text
---@field exclude_kinds string[]? LSP symbol kind names to hide, e.g. { "Variable" }
---@field collapse_kinds string[]? LSP symbol kind names left collapsed on load
---                                even when `auto_expand` is set
---@field debounce_ms integer?   edit-to-refresh delay
---@field max_cached_folds integer? folds remembered across all buffers

---@type keystone.symboltree.Config
local _defaults = {
    width_ratio = 0.2,
    track_cursor = true,
    auto_expand = true,
    show_detail = true,
    exclude_kinds = nil,
    collapse_kinds = { "Function", "Method", "Object" },
    debounce_ms = 500,
    max_cached_folds = 2048,
}

--- List-valued options a user supplies replace the default outright.
--- `vim.tbl_deep_extend` would otherwise merge them index by index, leaving
--- trailing defaults behind, e.g. { "Class" } over the default becoming
--- { "Class", "Method" }.
local _LIST_KEYS = { "exclude_kinds", "collapse_kinds" }

---The live options. Always this same table, so it is safe to capture at a
---module's top.
---@type keystone.symboltree.Config
M.current = vim.deepcopy(_defaults)

---A fresh copy of the defaults, as `apply()` starts from. Safe to mutate.
---@return keystone.symboltree.Config
function M.defaults()
    return vim.deepcopy(_defaults)
end

---@param opts table?
function M.apply(opts)
    cfgutil.apply(M.current, _defaults, opts)
    for _, key in ipairs(_LIST_KEYS) do
        if opts and opts[key] then
            M.current[key] = vim.deepcopy(opts[key])
        end
    end
end

return M
