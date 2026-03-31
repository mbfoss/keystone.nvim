local M = {}

---@class keystone.ViewProvider
---@field create_buffer fun(state:table?):number
---@field get_state (fun():table?)?

---@class keystone.ViewInfo
---@field name string
---@field provider keystone.ViewProvider

---@type table<string, keystone.ViewInfo>
local _registry = {}

function M.clear_views()
    _registry = {}
end

---Registers a new view provider.
---@param view_id string Unique identifier for the view.
---@param name string
---@param provider keystone.ViewProvider The provider definition.
function M.register_view(view_id, name, provider)
    assert(not _registry[view_id], string.format("View already registered: %s", view_id))
    assert(type(provider) == "table")
    _registry[view_id] = {
        name = name,
        provider = provider,
    }
end

---Returns a single view provider by ID.
---@return string[]
function M.get_view_ids()
    return vim.tbl_keys(_registry)
end

---Returns a single view provider by ID.
---@return keystone.ViewInfo[]
function M.get_views()
    local views = vim.tbl_values(_registry)
    table.sort(views, function(a, b) return a.name < b.name end)
    return views
end

---@param id string
---@return keystone.ViewInfo?
function M.get_view_info(id)
    local info = _registry[id]
    if not info then return end
    return {
        name = info.name,
        provider = info.provider,
    }
end

return M
