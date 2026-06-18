local M = {}

local icons    = require("keystone.icons")
local throttle = require("keystone.util.throttle")

local _redrawstatus = throttle.throttle_wrap(300, vim.cmd.redrawstatus)

---A section provider is a self-contained module (one per file under
---`keystone/statusline/`) that owns its state, highlights and lifecycle.
---@class keystone.statusline.Provider
---@field render     fun(bufnr: integer): string
---@field highlights table<string, vim.api.keyset.highlight>?
---@field enable     fun(on_change: fun())?
---@field disable    fun()?

---Complex sections live in their own provider files; simple stateless sections
---are defined inline below.
---@type table<string, keystone.statusline.Provider>
local _providers = {
  lsp_progress = require("keystone.statusline.lsp_progress"),
  symbol       = require("keystone.statusline.symbol"),
}

---A section can be a builtin name or a function returning a statusline string.
---Builtin names: "mode" | "git" | "filename" | "symbol" | "lsp_progress" | "diagnostics" | "filetype" | "position"
---@alias keystone.statusline.Section string | fun(bufnr: integer): string

---@class keystone.statusline.Sections
---@field left  keystone.statusline.Section[]
---@field right keystone.statusline.Section[]

---@class keystone.statusline.Config
---@field enabled  boolean
---@field sections keystone.statusline.Sections

local function _get_default_config()
  ---@type keystone.statusline.Config
  return {
    enabled = true,
    sections = {
      left  = { "mode", "git", "filename", "symbol" },
      right = { "lsp_progress", "diagnostics", "filetype", "position" },
    },
  }
end

---@type keystone.statusline.Config
M.config = _get_default_config()

-- ---------------------------------------------------------------------------
-- Simple builtin sections (stateless)
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
local function _section_git(bufnr)
  local branch = vim.b[bufnr].gitsigns_head or vim.g.gitsigns_head
  if not branch or branch == "" then return "" end
  return "%#KeystoneSLGit#  " .. branch:gsub("%%", "%%%%") .. " %*"
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

---@type table<string, vim.api.keyset.highlight>
local _BASE_HIGHLIGHTS = {
  KeystoneSLModeNormal  = { fg = "#6E94C9", bold = true },
  KeystoneSLModeInsert  = { fg = "#7BA87A", bold = true },
  KeystoneSLModeVisual  = { fg = "#9D82C7", bold = true },
  KeystoneSLModeReplace = { fg = "#B87A90", bold = true },
  KeystoneSLModeCommand = { fg = "#CDCDCD", bold = true },
  KeystoneSLGit         = { link = "" },
  KeystoneSLDiagError   = { link = "DiagnosticError" },
  KeystoneSLDiagWarn    = { link = "DiagnosticWarn" },
  KeystoneSLDiagHint    = { link = "DiagnosticHint" },
}

---Renderers for the simple builtin sections, merged with provider renderers
---in `_builtins()`.
---@type table<string, fun(bufnr: integer): string>
local _SIMPLE = {
  mode        = _section_mode,
  git         = _section_git,
  filename    = _section_filename,
  diagnostics = _section_diagnostics,
  filetype    = _section_filetype,
  position    = _section_position,
}

---@return table<string, fun(bufnr: integer): string>
local function _builtins()
  local builtins = vim.tbl_extend("error", {}, _SIMPLE)
  for name, provider in pairs(_providers) do
    builtins[name] = provider.render
  end
  return builtins
end

-- ---------------------------------------------------------------------------
-- Highlights
-- ---------------------------------------------------------------------------

local function _setup_highlights()
  local function def(name, opts)
    if next(vim.api.nvim_get_hl(0, { name = name })) == nil then
      vim.api.nvim_set_hl(0, name, opts)
    end
  end

  for name, opts in pairs(_BASE_HIGHLIGHTS) do
    def(name, opts)
  end
  for _, provider in pairs(_providers) do
    for name, opts in pairs(provider.highlights or {}) do
      def(name, opts)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

---@param section_list keystone.statusline.Section[]
---@param builtins      table<string, fun(bufnr: integer): string>
---@param bufnr        integer
---@return string
local function _render_sections(section_list, builtins, bufnr)
  local out = {}
  for _, section in ipairs(section_list) do
    local chunk
    if type(section) == "function" then
      chunk = section(bufnr)
    elseif type(section) == "string" then
      local fn = builtins[section]
      chunk = fn and fn(bufnr) or ""
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

    local builtins = _builtins()
    local secs     = M.config.sections
    local left     = _render_sections(secs.left,  builtins, bufnr)
    local right    = _render_sections(secs.right, builtins, bufnr)

    return left .. "%=" .. right
  end)
  return ok and result or ""
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local _enabled = false

function M.enable()
  if _enabled then return end
  _enabled = true

  _setup_highlights()
  vim.o.statusline = '%{%v:lua.require("keystone.statusline").render()%}'

  for _, provider in pairs(_providers) do
    if provider.enable then provider.enable(_redrawstatus) end
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

  for _, provider in pairs(_providers) do
    if provider.disable then provider.disable() end
  end

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
