local M = {}

local icons    = require("keystone.icons")
local throttle = require("keystone.util.throttle")

local _redrawstatus = throttle.throttle_wrap(300, vim.cmd.redrawstatus)
local _enabled = false

---A section provider renders one statusline section and optionally owns its own
---highlights and lifecycle. The built-in sections are registered exactly like
---user-provided ones — see `M.register`.
---
---  - `render`     returns the section text (statusline syntax); `""` to omit it.
---  - `highlights` highlight groups to define on enable / `ColorScheme`. They are
---                 only set if not already defined, so users can override them.
---  - `enable`     sets up any state/autocmds. Receives an `on_change` callback to
---                 invoke whenever the section's state changes, triggering a
---                 throttled `redrawstatus`.
---  - `disable`    tears down whatever `enable` set up.
---@class keystone.statusline.Provider
---@field render     fun(bufnr: integer): string
---@field highlights table<string, vim.api.keyset.highlight>?
---@field enable     fun(on_change: fun())?
---@field disable    fun()?

---A section is either the name of a registered provider or an inline function
---returning a statusline string.
---@alias keystone.statusline.Section string | fun(bufnr: integer): string

---@class keystone.statusline.Sections
---@field left  keystone.statusline.Section[]
---@field right keystone.statusline.Section[]

---@class keystone.statusline.Config
---@field enabled  boolean
---@field sections keystone.statusline.Sections

-- ---------------------------------------------------------------------------
-- Provider registry
-- ---------------------------------------------------------------------------

---@type table<string, keystone.statusline.Provider>
local _registry = {}

---Names of providers whose `enable` hook is currently running, so `disable`
---tears down exactly those — not whatever `M.config.sections` says *now*,
---which may have already changed by the time `disable` runs (see `M.setup`).
---@type table<string, true>
local _active = {}

---Whether `name` is referenced anywhere in the current config's sections, i.e.
---whether its `enable`/`disable` lifecycle should actually run.
---@param name string
---@return boolean
local function _is_used(name)
  for _, list in pairs(M.config.sections) do
    if vim.tbl_contains(list, name) then return true end
  end
  return false
end

---Define a highlight group only if it is not already defined, so user/colorscheme
---definitions win.
local function _def(name, opts)
  if next(vim.api.nvim_get_hl(0, { name = name })) == nil then
    vim.api.nvim_set_hl(0, name, opts)
  end
end

---@param provider keystone.statusline.Provider
local function _apply_highlights(provider)
  for name, opts in pairs(provider.highlights or {}) do
    _def(name, opts)
  end
end

---Register a section provider under `name` so it can be referenced from
---`config.sections`. A bare function is treated as a render-only provider.
---
---May be called at any time: if the statusline is already enabled, the
---provider's highlights are applied and its `enable` hook is run immediately.
---
---@param name     string
---@param provider keystone.statusline.Provider | fun(bufnr: integer): string
function M.register(name, provider)
  if type(provider) == "function" then
    provider = { render = provider }
  end
  assert(type(provider) == "table" and type(provider.render) == "function",
    "keystone.statusline: provider must have a `render` function")
  _registry[name] = provider
  if _enabled and _is_used(name) then
    _apply_highlights(provider)
    _active[name] = true
    if provider.enable then provider.enable(_redrawstatus) end
  end
end

---Remove a previously registered section provider, tearing it down if enabled.
---@param name string
function M.unregister(name)
  local provider = _registry[name]
  if not provider then return end
  if _active[name] and provider.disable then provider.disable() end
  _active[name] = nil
  _registry[name] = nil
end

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

local function _get_default_config()
  ---@type keystone.statusline.Config
  return {
    enabled = true,
    sections = {
      left  = { "mode", "git", "filename" },
      right = { "lsp_progress", "diagnostics", "filetype", "position" },
    },
  }
end

---@type keystone.statusline.Config
M.config = _get_default_config()

-- ---------------------------------------------------------------------------
-- Built-in simple sections (stateless). Complex ones live in their own files.
-- ---------------------------------------------------------------------------

local _MODE_MAP = {
  n       = { label = "NORMAL",   hl = "KeystoneSLModeNormal" },
  i       = { label = "INSERT",   hl = "KeystoneSLModeInsert" },
  v       = { label = "VISUAL",   hl = "KeystoneSLModeVisual" },
  V       = { label = "V-LINE",   hl = "KeystoneSLModeVisual" },
  ["\22"] = { label = "V-BLOCK",  hl = "KeystoneSLModeVisual" },
  c       = { label = "COMMAND",  hl = "KeystoneSLModeCommand" },
  r       = { label = "CONFIRM",  hl = "KeystoneSLModeCommand" },
  R       = { label = "REPLACE",  hl = "KeystoneSLModeReplace" },
  s       = { label = "SELECT",   hl = "KeystoneSLModeVisual" },
  S       = { label = "S-LINE",   hl = "KeystoneSLModeVisual" },
  ["\19"] = { label = "S-BLOCK",  hl = "KeystoneSLModeVisual" },
  t       = { label = "TERMINAL", hl = "KeystoneSLModeInsert" },
}

local function _section_mode(_)
  local raw  = vim.fn.mode()
  local info = _MODE_MAP[raw] or { label = "?", hl = "KeystoneSLModeNormal" }
  return "%#" .. info.hl .. "# " .. info.label .. " %*"
end

---@param bufnr integer
local function _section_filename(bufnr)
  if vim.bo[bufnr].buftype == "terminal" then
    return "%*  "
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return "%* [No Name]"
  end

  local filename = vim.fn.fnamemodify(name, ":t")
  local rel      = vim.fn.fnamemodify(name, ":~:.")
  local icon, _  = icons.get_icon(filename)
  local icon_str = icon ~= "" and ("%* " .. icon) or ""
  local mod      = vim.bo[bufnr].modified and " [+]" or ""
  local ro       = vim.bo[bufnr].readonly and " [ro]" or ""
  return icon_str .. "%* " .. rel:gsub("%%", "%%%%") .. mod .. ro
end

---@param bufnr integer
local function _section_diagnostics(bufnr)
  local counts = vim.diagnostic.count(bufnr)
  local e = counts[vim.diagnostic.severity.ERROR] or 0
  local w = counts[vim.diagnostic.severity.WARN]  or 0
  local h = counts[vim.diagnostic.severity.HINT]  or 0

  local parts = {}
  if e > 0 then table.insert(parts, "%#KeystoneSLDiagError#󰅚 " .. e) end
  if w > 0 then table.insert(parts, "%#KeystoneSLDiagWarn#󰀪 " .. w) end
  if h > 0 then table.insert(parts, "%#KeystoneSLDiagHint#󰋽 " .. h) end
  if #parts == 0 then return "" end

  return table.concat(parts, " ") .. " %*"
end

---@param bufnr integer
local function _section_filetype(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft == "" then return "" end
  return "%* " .. ft .. " "
end

local function _section_position(_)
  return "%* %4l:%-3c "
end

---Register the built-in sections through the same public registry users use.
local function _register_builtins()
  M.register("mode", {
    render = _section_mode,
    highlights = {
      KeystoneSLModeNormal  = { fg = "#6E94C9", bold = true },
      KeystoneSLModeInsert  = { fg = "#7BA87A", bold = true },
      KeystoneSLModeVisual  = { fg = "#9D82C7", bold = true },
      KeystoneSLModeReplace = { fg = "#B87A90", bold = true },
      KeystoneSLModeCommand = { fg = "#CDCDCD", bold = true },
    },
  })
  M.register("git", require("keystone.statusline.git"))
  M.register("filename", _section_filename)
  M.register("diagnostics", {
    render = _section_diagnostics,
    highlights = {
      KeystoneSLDiagError = { link = "DiagnosticError" },
      KeystoneSLDiagWarn  = { link = "DiagnosticWarn" },
      KeystoneSLDiagHint  = { link = "DiagnosticHint" },
    },
  })
  M.register("filetype", _section_filetype)
  M.register("position", _section_position)
  M.register("lsp_progress", require("keystone.statusline.lsp_progress"))
end

_register_builtins()

-- ---------------------------------------------------------------------------
-- Highlights
-- ---------------------------------------------------------------------------

local function _setup_highlights()
  for name, provider in pairs(_registry) do
    if _is_used(name) then _apply_highlights(provider) end
  end
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

---@param section_list keystone.statusline.Section[]
---@param bufnr        integer
---@return string
local function _render_sections(section_list, bufnr)
  local out = {}
  for _, section in ipairs(section_list) do
    local chunk
    if type(section) == "function" then
      chunk = section(bufnr)
    elseif type(section) == "string" then
      local provider = _registry[section]
      chunk = provider and provider.render(bufnr) or ""
    end
    if chunk and chunk ~= "" then
      table.insert(out, chunk)
    end
  end
  return table.concat(out)
end

function M.render()
  local ok, result = pcall(function()
    local winid = vim.g.statusline_winid
    if not winid or winid == 0 then
      winid = vim.api.nvim_get_current_win()
    end
    if not vim.api.nvim_win_is_valid(winid) then return "" end
    local cfg = vim.api.nvim_win_get_config(winid)
    if cfg.relative ~= "" then return "" end
    local bufnr = vim.api.nvim_win_get_buf(winid)

    local secs  = M.config.sections
    local left  = _render_sections(secs.left,  bufnr)
    local right = _render_sections(secs.right, bufnr)

    return left .. "%=" .. right
  end)
  return ok and result or ""
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function M.enable()
  if _enabled then return end
  _enabled = true

  _setup_highlights()
  vim.o.statusline = '%{%v:lua.require("keystone.statusline").render()%}'

  for name, provider in pairs(_registry) do
    if _is_used(name) then
      _active[name] = true
      if provider.enable then provider.enable(_redrawstatus) end
    end
  end

  local group = vim.api.nvim_create_augroup("keystone_statusline", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = _setup_highlights,
  })
end

function M.disable()
  if not _enabled then return end
  _enabled = false

  for name in pairs(_active) do
    local provider = _registry[name]
    if provider and provider.disable then provider.disable() end
  end
  _active = {}

  vim.api.nvim_del_augroup_by_name("keystone_statusline")
  vim.o.statusline = ""
end

---@param opts keystone.statusline.Config?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
  if M.config.enabled then
    M.enable()
  else
    M.disable()
  end
end

return M
