local M = {}

local icons     = require("keystone.icons")
local lspsymbol = require("keystone.util.lspsymbol")
local throttle  = require("keystone.util.throttle")

local _redrawstatus = throttle.throttle_wrap(300, vim.cmd.redrawstatus)

---A section can be a builtin name or a function returning a statusline string.
---Builtin names: "mode" | "git" | "filename" | "lsp_progress" | "diagnostics" | "filetype" | "position"
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

local function _setup_highlights()
  local function def(name, opts)
    if next(vim.api.nvim_get_hl(0, { name = name })) == nil then
      vim.api.nvim_set_hl(0, name, opts)
    end
  end

  def("KeystoneSLModeNormal",  { fg = "#6E94C9", bold = true })
  def("KeystoneSLModeInsert",  { fg = "#7BA87A", bold = true })
  def("KeystoneSLModeVisual",  { fg = "#9D82C7", bold = true })
  def("KeystoneSLModeReplace", { fg = "#B87A90", bold = true })
  def("KeystoneSLModeCommand", { fg = "#CDCDCD", bold = true })
  def("KeystoneSLGit",         { link = "" })
  def("KeystoneSLLspProgress", { link = "Statusbar" })
  def("KeystoneSLSymbol",      { link = "Statusbar" })
  def("KeystoneSLDiagError",   { link = "DiagnosticError" })
  def("KeystoneSLDiagWarn",    { link = "DiagnosticWarn" })
  def("KeystoneSLDiagHint",    { link = "DiagnosticHint" })
end

---@class keystone.statusline.LspToken
---@field name       string
---@field client_id  integer
---@field percentage integer?

---@type table<string|integer, keystone.statusline.LspToken>
local _lsp_progress = {}

-- [bufnr] = SymbolInfo[] — last chain received from lspsymbol
local _symbol_chains = {}
local _lspsymbol_unsub = nil

local _FUNCTION_KINDS = { [5] = true, [6] = true, [9] = true, [12] = true, [23] = true }

local _SYMBOL_ICONS = {
  [5]  = "󰌗", -- Class
  [6]  = "󰆧", -- Method
  [9]  = "",  -- Constructor
  [12] = "󰊕", -- Function
  [23] = "󰙅", -- Struct
}

-- ---------------------------------------------------------------------------
-- Built-in section renderers
-- ---------------------------------------------------------------------------

local function _section_mode(_)
  local raw  = vim.fn.mode()
  local info = _MODE_MAP[raw] or { label = "?", hl = "KeystoneSLModeNormal" }
  return "%#" .. info.hl .. "# " .. info.label .. " %*"
end

---@param bufnr integer
local function _section_git(bufnr)
  local branch = vim.b[bufnr].gitsigns_head or vim.g.gitsigns_head
  if not branch or branch == "" then return "" end
  return "%#KeystoneSLGit#  " .. branch:gsub("%%", "%%%%") .. " %*"
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

---@param bufnr integer
local function _section_lsp_progress(bufnr)
  local parts = {}
  for _, token in pairs(_lsp_progress) do
    if vim.lsp.buf_is_attached(bufnr, token.client_id) then
      local text = token.percentage and (token.name .. " " .. token.percentage .. "%%") or token.name
      table.insert(parts, text)
    end
  end
  if #parts == 0 then return "" end
  return "%#KeystoneSLLspProgress# 󰒓 " .. table.concat(parts, "  ") .. " %*"
end

local function _section_symbol(bufnr)
  local chain = _symbol_chains[bufnr]
  if not chain or #chain == 0 then return "" end
  local sym
  for i = #chain, 1, -1 do
    if _FUNCTION_KINDS[chain[i].kind] then
      sym = chain[i]
      break
    end
  end
  if not sym then return "" end
  local icon = _SYMBOL_ICONS[sym.kind] or "󰊕"
  return "%#KeystoneSLSymbol# " .. icon .. " " .. sym.name:gsub("%%", "%%%%") .. " %*"
end

local function _section_position(_)
  return "%* %4l:%-3c "
end

---@type table<string, fun(bufnr: integer): string>
local _BUILTINS = {
  mode         = _section_mode,
  git          = _section_git,
  filename     = _section_filename,
  symbol       = _section_symbol,
  lsp_progress = _section_lsp_progress,
  diagnostics  = _section_diagnostics,
  filetype     = _section_filetype,
  position     = _section_position,
}

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

---@param sections keystone.statusline.Section[]
---@param bufnr    integer
---@return string
local function _render_sections(sections, bufnr)
  local out = {}
  for _, section in ipairs(sections) do
    local chunk
    if type(section) == "function" then
      chunk = section(bufnr)
    elseif type(section) == "string" then
      local fn = _BUILTINS[section]
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

    local sections = M.config.sections
    local left  = _render_sections(sections.left,  bufnr)
    local right = _render_sections(sections.right, bufnr)

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

  _lspsymbol_unsub = lspsymbol.subscribe(function(bufnr, chain)
    _symbol_chains[bufnr] = chain
    _redrawstatus()
  end)

  local group = vim.api.nvim_create_augroup("keystone_statusline", { clear = true })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = _setup_highlights,
  })

  vim.api.nvim_create_autocmd("LspProgress", {
    group = group,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if not client then return end
      local params = ev.data.params
      local val    = params and params.value
      if not val then return end
      local token = params.token
      if val.kind == "end" then
        _lsp_progress[token] = nil
      else
        _lsp_progress[token] = { name = client.name, client_id = ev.data.client_id, percentage = val.percentage }
      end
      _redrawstatus()
    end,
  })
end

function M.disable()
  if not _enabled then return end
  _enabled = false
  if _lspsymbol_unsub then
    _lspsymbol_unsub()
    _lspsymbol_unsub = nil
  end
  _symbol_chains = {}
  _lsp_progress = {}
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
