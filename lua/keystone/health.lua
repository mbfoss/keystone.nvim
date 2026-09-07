---@brief Health check for keystone.nvim, run with `:checkhealth keystone`.
---
---Reports the Neovim version, which modules are active (their `setup()` has
---run) and which are not, then one section per module whose config differs from
---its defaults. A module left entirely at its defaults gets no section: the
---active list already said it is running. Per-module deep checks live in their
---own health modules (`:checkhealth keystone.tsconfig`).

local M = {}

local _h = vim.health

---@return string[]
local function _module_names()
  local names = require("keystone").modules()
  table.sort(names)
  return names
end

--- Whether `keystone.<name>` exists on the runtimepath.
---@param name string
---@return boolean
local function _module_exists(name)
  return #vim.api.nvim_get_runtime_file("lua/keystone/" .. name .. ".lua", false) > 0
end

--- Whether the module has been set up. Reads through `package.loaded` rather
--- than requiring: an unloaded module is itself the answer, and loading it here
--- would not have run its `setup()` anyway.
---@param name string
---@return table? mod the loaded module, when it is active
local function _active(name)
  local mod = package.loaded["keystone." .. name]
  if mod and (type(mod.is_setup) ~= "function" or mod.is_setup()) then
    return mod
  end
end

--- Collect the options whose value differs from the default, as flat paths
--- (`enabled`, `builtin.marks`) with the value now in force. Lists are compared
--- whole: a `triggers` is one option, not one option per trigger.
---@param current table
---@param defaults table
---@param prefix string path of the enclosing table, "" at the top level
---@param out table[]
---@return table[]
local function _diff_config(current, defaults, prefix, out)
  for key, value in pairs(current) do
    local path = prefix .. tostring(key)
    local default = defaults[key]
    if type(value) == "table" and type(default) == "table" and not vim.islist(value) then
      _diff_config(value, default, path .. ".", out)
    elseif not vim.deep_equal(value, default) then
      table.insert(out, {
        path = path,
        value = vim.inspect(value),
        -- `setup()` merges opts wholesale, so a misspelled option is kept
        -- silently; only a key the defaults never mention can be one.
        unknown = default == nil,
      })
    end
  end
  return out
end

--- The options an active module holds that differ from its defaults, sorted by
--- path. Empty for a module that takes no options.
---@param mod table
---@return table[]
local function _changed_options(mod)
  if type(mod.get_default_config) ~= "function" or type(mod.config) ~= "table" then
    return {}
  end
  local diffs = _diff_config(mod.config, mod.get_default_config(), "", {})
  table.sort(diffs, function(a, b) return a.path < b.path end)
  return diffs
end

local function _check_requirements()
  _h.start("keystone: requirements")
  if vim.fn.has("nvim-0.11") == 1 then
    _h.ok("Neovim " .. tostring(vim.version()))
  else
    _h.error("keystone.nvim requires Neovim >= 0.11")
  end
end

---@param names string[]
---@return table<string, table> active  module name -> loaded module
local function _check_modules(names)
  _h.start("keystone: modules")

  local active_names, inactive, active = {}, {}, {}
  for _, name in ipairs(names) do
    if not _module_exists(name) then
      _h.error(("keystone.%s does not exist on the runtimepath"):format(name), {
        ("require('keystone').setup({ %s = ... }) would fail"):format(name),
      })
    else
      local mod = _active(name)
      if mod then
        table.insert(active_names, name)
        active[name] = mod
      else
        table.insert(inactive, name)
      end
    end
  end

  if #active_names > 0 then
    _h.info("active: " .. table.concat(active_names, ", "))
  else
    _h.warn("active: none", { "call require('keystone').setup({ ... })" })
  end
  _h.info("inactive: " .. (#inactive > 0 and table.concat(inactive, ", ") or "none"))

  return active
end

--- One section per active module whose config was changed, listing only what
--- differs. Modules left at their defaults are omitted.
---@param names string[]
---@param active table<string, table>
local function _check_configs(names, active)
  for _, name in ipairs(names) do
    local mod = active[name]
    local diffs = mod and _changed_options(mod) or {}
    if #diffs > 0 then
      _h.start("keystone." .. name)
      local lines = {}
      for _, entry in ipairs(diffs) do
        table.insert(lines, ("  %s = %s"):format(entry.path, entry.value))
      end
      _h.info(table.concat(lines, "\n"))
      for _, entry in ipairs(diffs) do
        if entry.unknown then
          _h.warn(("`%s` is not an option this module defines"):format(entry.path), {
            "check its spelling against the module's default config",
          })
        end
      end
    end
  end
end

function M.check()
  local names = _module_names()
  _check_requirements()
  local active = _check_modules(names)
  _check_configs(names, active)
end

return M
