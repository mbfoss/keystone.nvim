local M = {}

local _icons = require("keystone.icons")

---@class keystone.statusline.Config
---@field enabled boolean

local function _get_default_config()
  ---@type keystone.statusline.Config
  return { enabled = true }
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
  local function hl_attr(name, attr)
    local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and h then return h[attr] end
  end

  local sl_bg = hl_attr("StatusLine", "bg")

  local function def(name, opts)
    if sl_bg then
      opts.bg = opts.bg or sl_bg
    end
    vim.api.nvim_set_hl(0, name, opts)
  end

  def("KeystoneSLModeNormal",  { fg = 0x89B4FA, bold = true })
  def("KeystoneSLModeInsert",  { fg = 0xA6E3A1, bold = true })
  def("KeystoneSLModeVisual",  { fg = 0xCBA6F7, bold = true })
  def("KeystoneSLModeReplace", { fg = 0xF38BA8, bold = true })
  def("KeystoneSLModeCommand", { fg = 0xF9E2AF, bold = true })
  def("KeystoneSLGit",         { fg = 0x7F849C })
  def("KeystoneSLDiagError",   { fg = 0xF38BA8 })
  def("KeystoneSLDiagWarn",    { fg = 0xF9E2AF })
  def("KeystoneSLDiagHint",    { fg = 0x94E2D5 })
end

local function _section_mode()
  local raw = vim.fn.mode(1)
  local info = _MODE_MAP[raw:sub(1, 1)] or { label = raw:upper(), hl = "KeystoneSLModeNormal" }
  return "%#" .. info.hl .. "# " .. info.label .. " %#StatusLine#"
end

---@param bufnr integer
local function _section_git(bufnr)
  local branch = vim.b[bufnr].gitsigns_head or vim.g.gitsigns_head
  if not branch or branch == "" then return "" end
  return "%#KeystoneSLGit#  " .. branch:gsub("%%", "%%%%") .. " %#StatusLine#"
end

---@param bufnr integer
local function _section_filename(bufnr)
  if vim.bo[bufnr].buftype == "terminal" then
    return "%#StatusLine#  "
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return "%#StatusLine# [No Name]"
  end

  local filename = vim.fn.fnamemodify(name, ":t")
  local rel      = vim.fn.fnamemodify(name, ":~:.")
  local icon, icon_hl = _icons.get_icon(filename)
  local icon_str = icon ~= "" and ("%#" .. icon_hl .. "# " .. icon) or ""
  local mod      = vim.bo[bufnr].modified and " %#KeystoneSLDiagWarn#●%#StatusLine#" or ""
  local ro       = vim.bo[bufnr].readonly and " %#KeystoneSLDiagError#%#StatusLine#" or ""
  return icon_str .. "%#StatusLine# " .. rel:gsub("%%", "%%%%") .. mod .. ro
end

---@param bufnr integer
local function _section_diagnostics(bufnr)
  local counts = vim.diagnostic.count(bufnr)
  local e = counts[vim.diagnostic.severity.ERROR] or 0
  local w = counts[vim.diagnostic.severity.WARN]  or 0
  local h = counts[vim.diagnostic.severity.HINT]  or 0

  local parts = {}
  if e > 0 then table.insert(parts, "%#KeystoneSLDiagError# " .. e) end
  if w > 0 then table.insert(parts, "%#KeystoneSLDiagWarn# " .. w) end
  if h > 0 then table.insert(parts, "%#KeystoneSLDiagHint#󰌶 " .. h) end
  if #parts == 0 then return "" end

  return table.concat(parts, " ") .. " %#StatusLine#"
end

---@param bufnr integer
local function _section_filetype(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft == "" then return "" end
  return "%#StatusLine# " .. ft .. " "
end

local function _section_position()
  return "%#StatusLine# %l:%c "
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

    local left = _section_mode()
      .. _section_git(bufnr)
      .. _section_filename(bufnr)

    local right = _section_diagnostics(bufnr)
      .. _section_filetype(bufnr)
      .. _section_position()

    return left .. "%=" .. right
  end)
  return ok and result or ""
end

local _enabled = false

function M.enable()
  if _enabled then return end
  _enabled = true

  _setup_highlights()
  vim.o.statusline = '%{%v:lua.require("keystone.statusline").render()%}'

  local group = vim.api.nvim_create_augroup("keystone_statusline", { clear = true })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = _setup_highlights,
  })
end

function M.disable()
  if not _enabled then return end
  _enabled = false
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
