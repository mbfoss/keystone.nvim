-- IMPORTANT: keep this module light for lazy loading

local M = {}

---@class keystone.Config
---@field use_fd_find boolean

-- IMPORTANT: keep this module light for lazy loading

local function _get_default_config()
    ---@type keystone.Config
    return {
        use_fd_find = false,
    }
end

---@type keystone.Config
M.config = _get_default_config()

-----------------------------------------------------------
-- Setup (user config)
-----------------------------------------------------------

---@param opts keystone.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
end

return M
