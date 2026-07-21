local M = {}

-- ---------------------------------------------------------------------------
-- LSP breadcrumbs in the winbar.
--
-- This module is only the entry point: config, the `:Breadcrumbs` command and
-- the enable/disable switch. The implementation lives in
-- `keystone.breadcrumbs.core` and is required on first enable, so requiring
-- (or `setup()`ing) this module while disabled stays cheap.
-- ---------------------------------------------------------------------------

local usercmd = require("keystone.tk.usercmd")

---@class keystone.breadcrumbs.Config
---@field enabled boolean Enable breadcrumbs on setup (default: false)

local function _get_default_config()
  ---@type keystone.breadcrumbs.Config
  return {
    enabled = false,
  }
end

---@type keystone.breadcrumbs.Config
M.config = _get_default_config()

---@type keystone.breadcrumbs.Core?
local _core = nil

---@return keystone.breadcrumbs.Core
local function _load_core()
  if not _core then
    _core = require("keystone.breadcrumbs.core")
  end
  return _core
end

--- Renders the winbar for the current window. Called from the `winbar` option;
--- returns an empty string when the implementation was never loaded.
---@return string
function M.render()
  return _core and _core.render() or ""
end

function M.enable()
  _load_core().enable()
end

function M.disable()
  -- Nothing can be enabled while the core is unloaded.
  if _core then _core.disable() end
end

---@return boolean
function M.is_enabled()
  return _core ~= nil and _core.is_enabled()
end

--- Toggles breadcrumbs on/off.
---@return boolean enabled the state after toggling
function M.toggle()
  if M.is_enabled() then
    M.disable()
  else
    M.enable()
  end
  return M.is_enabled()
end

---@type table<string, fun()>
local _SUBCOMMANDS = {
  enable = function() M.enable() end,
  disable = function() M.disable() end,
  toggle = function() M.toggle() end,
}

local function _register_user_cmd()
  usercmd.register_user_cmd("Breadcrumbs", function(_, args)
    local action = args[1] or "toggle"
    local fn = _SUBCOMMANDS[action]
    if not fn then
      vim.notify("Breadcrumbs: unknown action " .. vim.inspect(action), vim.log.levels.WARN)
      return
    end
    fn()
  end, {
    desc = "Enable, disable or toggle LSP breadcrumbs in the winbar",
    subcommand = function(_, rest)
      if #rest > 0 then return {} end
      return vim.tbl_keys(_SUBCOMMANDS)
    end,
  })
end

---@param opts keystone.breadcrumbs.Config?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
  _register_user_cmd()
  if M.config.enabled then
    M.enable()
  else
    M.disable()
  end
end

return M
