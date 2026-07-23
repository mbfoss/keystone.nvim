local M             = {}

local icons         = require("keystone.icons")
local throttle      = require("keystone.tk.throttle")

local _redrawstatus = throttle.throttle_wrap(300, vim.cmd.redrawstatus)
local _enabled      = false

---A section provider renders one statusline section and optionally owns its own
---highlights and lifecycle. The built-in sections are registered exactly like
---user-provided ones — see `M.register`.
---
---  - `render`     returns the section text (statusline syntax); `""` to omit it.
---                 It may return a *second* value: a compact variant used when the
---                 window is too narrow to fit every section at full width. The fit
---                 pass switches the least important sections to their short form
---                 before dropping any outright. Return only one value (or an equal
---                 second one) when a section has no shorter form. Returning both in
---                 one call lets a section share work between the two variants.
---  - `highlights` highlight groups to define on enable / `ColorScheme`. They are
---                 only set if not already defined, so users can override them.
---  - `enable`     sets up any state/autocmds. Receives an `on_change` callback to
---                 invoke whenever the section's state changes, triggering a
---                 throttled `redrawstatus`.
---  - `disable`    tears down whatever `enable` set up.
---@class keystone.statusline.Provider
---@field render      fun(bufnr: integer): string, string?
---@field highlights? table<string, vim.api.keyset.highlight>
---@field enable?     fun(on_change: fun())
---@field disable?    fun()

---A section is either the name of a registered provider or an inline function
---returning a statusline string (and, optionally, a short variant as a second
---return — see `Provider.render`).
---@alias keystone.statusline.Section string | fun(bufnr: integer): string, string?

---@class keystone.statusline.Sections
---@field left  keystone.statusline.Section[]
---@field right keystone.statusline.Section[]

---Section names ordered by priority, **most important first**. When the
---window is too narrow to hold every section, the least important sections are
---dropped one at a time until the rest fit — starting from the end of this
---list. Named sections not listed here are considered lower priority than any
---listed one (dropped first); inline function sections are never dropped.
---@alias keystone.statusline.Priority string[]
---
---@class keystone.statusline.Config
---@field enabled  boolean
---@field sections keystone.statusline.Sections
---@field priority keystone.statusline.Priority

-- ---------------------------------------------------------------------------
-- Provider registry
-- ---------------------------------------------------------------------------

---@type table<string, keystone.statusline.Provider>
local _registry     = {}

---Names of providers whose `enable` hook is currently running, so `disable`
---tears down exactly those — not whatever `M.config.sections` says *now*,
---which may have already changed by the time `disable` runs (see `M.setup`).
---@type table<string, true>
local _active       = {}

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
      left  = { "mode", "git", "filename", "symbol_path" },
      right = { "lsp_progress", "diagnostics", "filetype", "position" },
    },
    priority = {
      "filename",
      "position",
      "diagnostics",
      "mode",
      "git",
      "filetype",
      "lsp_progress",
      "symbol_path",
    },
  }
end

---@type keystone.statusline.Config
M.config = _get_default_config()

-- ---------------------------------------------------------------------------
-- Built-in simple sections (stateless). Complex ones live in their own files.
-- ---------------------------------------------------------------------------

local _MODE_MAP = {
  n       = { label = "NORMAL", short = "N", hl = "KeystoneSLModeNormal" },
  i       = { label = "INSERT", short = "I", hl = "KeystoneSLModeInsert" },
  v       = { label = "VISUAL", short = "V", hl = "KeystoneSLModeVisual" },
  V       = { label = "V-LINE", short = "V", hl = "KeystoneSLModeVisual" },
  ["\22"] = { label = "V-BLOCK", short = "V", hl = "KeystoneSLModeVisual" },
  c       = { label = "COMMAND", short = "C", hl = "KeystoneSLModeCommand" },
  r       = { label = "CONFIRM", short = "?", hl = "KeystoneSLModeCommand" },
  R       = { label = "REPLACE", short = "R", hl = "KeystoneSLModeReplace" },
  s       = { label = "SELECT", short = "S", hl = "KeystoneSLModeVisual" },
  S       = { label = "S-LINE", short = "S", hl = "KeystoneSLModeVisual" },
  ["\19"] = { label = "S-BLOCK", short = "S", hl = "KeystoneSLModeVisual" },
  t       = { label = "TERMINAL", short = "T", hl = "KeystoneSLModeInsert" },
}

--- Full mode is the word label; the short form is the single-character label.
---@return string full, string short
local function _section_mode(_)
  local info = _MODE_MAP[vim.fn.mode()] or { label = "?", short = "?", hl = "KeystoneSLModeNormal" }
  local prefix = "%#" .. info.hl .. "# "
  return prefix .. info.label .. " %*", prefix .. info.short .. " %*"
end

--- Full filename is the path relative to cwd; the short form is the tail only.
---@param bufnr integer
---@return string full, string short
local function _section_filename(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return "%* [No Name]", "%* [No Name]"
  end

  local filename, rel, tail
  if vim.bo[bufnr].buftype == "" then
    filename = vim.fn.fnamemodify(name, ":t")
    rel      = vim.fn.fnamemodify(name, ":~:.")
    tail     = filename
  else
    filename = ""
    tail     = name:match("([^/\\]+)$") or name
    rel      = tail
  end
  local icon     = icons.get_icon(filename)
  local icon_str = icon ~= "" and ("%* " .. icon) or ""
  local mod      = vim.bo[bufnr].modified and " [+]" or ""
  local ro       = vim.bo[bufnr].readonly and " [ro]" or ""
  local suffix   = mod .. ro
  return icon_str .. "%* " .. rel:gsub("%%", "%%%%") .. suffix .. " ",
      icon_str .. "%* " .. tail:gsub("%%", "%%%%") .. suffix .. " "
end

---@param bufnr integer
local function _section_diagnostics(bufnr)
  local counts = vim.diagnostic.count(bufnr)
  local e = counts[vim.diagnostic.severity.ERROR] or 0
  local w = counts[vim.diagnostic.severity.WARN] or 0
  local h = counts[vim.diagnostic.severity.HINT] or 0

  local parts = {}
  if e > 0 then table.insert(parts, "%#KeystoneSLDiagError#󰅚 " .. e) end
  if w > 0 then table.insert(parts, "%#KeystoneSLDiagWarn#󰀪 " .. w) end
  if h > 0 then table.insert(parts, "%#KeystoneSLDiagHint#󰋽 " .. h) end
  if #parts == 0 then return "" end

  return table.concat(parts, " ") .. " %*"
end

---@param bufnr integer
local function _section_filetype(bufnr)
  if vim.bo[bufnr].buftype ~= "" then return end
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
  M.register("symbol_path", require("keystone.statusline.symbol_path"))
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

---One rendered section, carrying the state the fit pass needs. `text`/`width`
---track the currently-selected variant; the fit pass may swap them for the
---short variant (`short_text`/`short_width`) before dropping the section.
---@class keystone.statusline._Entry
---@field text        string   currently-selected statusline text (never empty)
---@field width       integer  display width of `text`, measured once
---@field short_text  string   short variant (equals `text` when there is none)
---@field short_width integer  display width of `short_text`
---@field rank        integer? priority rank; lower = more important, `nil` = never dropped
---@field shown       boolean  whether it is currently kept in the output

---Priority rank of a section: its 1-based index in `config.priority` (lower is
---more important, dropped last). Named sections that are not listed rank after
---every listed one. Inline function sections cannot be named, so they return
---`nil` and are never dropped.
---@param section keystone.statusline.Section
---@return integer?
local function _rank(section)
  if type(section) ~= "string" then return nil end
  for i, name in ipairs(M.config.priority) do
    if name == section then return i end
  end
  return math.huge
end

---Render each section once and measure its display width (statusline widths are
---additive — highlight/field syntax stays zero- or fixed-width regardless of
---neighbours — so per-section widths can later be summed and subtracted without
---re-measuring).
---@param section_list keystone.statusline.Section[]
---@param bufnr        integer
---@param winid        integer
---@return keystone.statusline._Entry[]
local function _build_entries(section_list, bufnr, winid)
  local entries = {}
  for _, section in ipairs(section_list) do
    local text, short
    if type(section) == "function" then
      text, short = section(bufnr)
    elseif type(section) == "string" then
      local provider = _registry[section]
      if provider then text, short = provider.render(bufnr) end
    end
    if text and text ~= "" then
      -- A section with no shorter form reuses its full text/width — measured
      -- once, since the statusline eval is the costly part here.
      local width = vim.api.nvim_eval_statusline(text, { winid = winid }).width
      local has_short = short and short ~= "" and short ~= text
      entries[#entries + 1] = {
        text        = text,
        width       = width,
        short_text  = has_short and short or text,
        short_width = has_short and vim.api.nvim_eval_statusline(short, { winid = winid }).width or width,
        rank        = _rank(section),
        shown       = true,
      }
    end
  end
  return entries
end

---@param entries keystone.statusline._Entry[]
---@return string
local function _concat_shown(entries)
  local parts = {}
  for _, entry in ipairs(entries) do
    if entry.shown then parts[#parts + 1] = entry.text end
  end
  return table.concat(parts)
end

---Shrink the statusline to the window width in two passes over the same drop
---order (least important first, and among ties the later one first): first
---switch sections to their short variant, then — if that is still not enough —
---hide sections outright. Operates purely on the pre-measured widths; the only
---string touched is swapping an entry to its already-rendered short text.
---The drop order is sorted once, so the whole pass is O(n log n).
---@param left  keystone.statusline._Entry[]
---@param right keystone.statusline._Entry[]
---@param winid integer
local function _fit(left, right, winid)
  local used = 0
  for _, list in ipairs({ left, right }) do
    for _, entry in ipairs(list) do
      used = used + entry.width
    end
  end

  local win_width = vim.api.nvim_win_get_width(winid)
  if used <= win_width then return end

  -- Over budget (the uncommon case): now collect the droppable sections,
  -- tagging each with its position so ties break toward the later one.
  local droppable = {}
  local ord = 0
  for _, list in ipairs({ left, right }) do
    for _, entry in ipairs(list) do
      if entry.rank then
        ord = ord + 1
        droppable[#droppable + 1] = { entry = entry, ord = ord }
      end
    end
  end

  table.sort(droppable, function(a, b)
    if a.entry.rank ~= b.entry.rank then return a.entry.rank > b.entry.rank end
    return a.ord > b.ord
  end)

  -- Pass 1: switch to short variants, starting from the least important.
  for _, item in ipairs(droppable) do
    local entry = item.entry
    if entry.short_width < entry.width then
      used        = used - (entry.width - entry.short_width)
      entry.text  = entry.short_text
      entry.width = entry.short_width
      if used <= win_width then return end
    end
  end

  -- Pass 2: still too wide — hide sections, starting from the least important.
  for _, item in ipairs(droppable) do
    item.entry.shown = false
    used = used - item.entry.width
    if used <= win_width then return end
  end
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
    local left  = _build_entries(secs.left, bufnr, winid)
    local right = _build_entries(secs.right, bufnr, winid)
    _fit(left, right, winid)

    return _concat_shown(left) .. "%=" .. _concat_shown(right)
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
