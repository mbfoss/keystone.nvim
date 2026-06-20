local M = {}

local _features = require("keystone.tweaks.features")

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

---@class keystone.tweaks.Config
---@field enabled boolean? master switch; when false `setup` tears every feature down
---@field highlight_on_yank boolean? briefly highlight yanked text (`TextYankPost`)
---@field yank_hlgroup string? highlight group used by `highlight_on_yank`
---@field yank_timeout integer? how long the yank highlight stays, in ms
---@field restore_cursor boolean? jump to the last cursor position when reopening a file
---@field auto_create_dir boolean? create missing parent directories when saving
---@field auto_reload boolean? reload files changed outside Neovim (`autoread` + `checktime`)
---@field equalize_splits boolean? re-balance splits on `VimResized`
---@field quick_close boolean? close utility buffers (help, qf, ...) with `q`
---@field quick_close_filetypes string[]? filetypes affected by `quick_close`
---@field disable_auto_comment boolean? stop auto-continuing comment leaders on new lines
---@field trim_whitespace boolean? strip trailing whitespace on save (off by default)

---@return keystone.tweaks.Config
local function _get_default_config()
  ---@type keystone.tweaks.Config
  return {
    enabled              = true,
    highlight_on_yank    = true,
    yank_hlgroup         = "IncSearch",
    yank_timeout         = 200,
    restore_cursor       = true,
    auto_create_dir      = true,
    auto_reload          = true,
    equalize_splits      = true,
    quick_close          = false,
    quick_close_filetypes = {
      "help", "qf", "man", "lspinfo", "checkhealth",
      "startuptime", "query", "notify", "git",
    },
    disable_auto_comment = false,
    trim_whitespace      = false,
  }
end

---@type keystone.tweaks.Config
M.config = _get_default_config()

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

-- Stable iteration/listing order for features (a plain table has none).
---@type string[]
local _feature_names = {
  "highlight_on_yank",
  "restore_cursor",
  "auto_create_dir",
  "auto_reload",
  "equalize_splits",
  "quick_close",
  "disable_auto_comment",
  "trim_whitespace",
}

-- Names of the features currently installed.
---@type table<string, boolean>
local _active = {}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

---@return string[]
function M.feature_names()
  return vim.deepcopy(_feature_names)
end

---@param name string
---@return boolean
function M.is_active(name)
  return _active[name] == true
end

-- Install a single feature. No-op when it is unknown or already active.
---@param name string
function M.enable_feature(name)
  local feat = _features[name]
  if not feat or _active[name] then return end
  feat.setup(M.config)
  _active[name] = true
end

-- Tear a single feature down by deleting its augroup.
---@param name string
function M.disable_feature(name)
  local feat = _features[name]
  if not feat or not _active[name] then return end
  pcall(vim.api.nvim_del_augroup_by_name, feat.augroup)
  _active[name] = nil
end

---@param name string
function M.toggle_feature(name)
  if _active[name] then
    M.disable_feature(name)
  else
    M.enable_feature(name)
  end
end

-- Enable every feature whose config flag is set.
function M.enable()
  for _, name in ipairs(_feature_names) do
    if M.config[name] then
      M.enable_feature(name)
    end
  end
end

-- Tear every active feature down.
function M.disable()
  for _, name in ipairs(_feature_names) do
    M.disable_feature(name)
  end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

---@param opts keystone.tweaks.Config?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

  -- Re-apply from a clean slate so `setup` is idempotent.
  M.disable()
  if M.config.enabled then
    M.enable()
  end
end

return M
