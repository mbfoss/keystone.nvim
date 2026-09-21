local M             = {}

local icons         = require("keystone.icons")
local throttle      = require("keystone.util.throttle")
local cfgutil       = require("keystone.util.config")

local _redrawstatus = throttle.throttle_wrap(300, vim.cmd.redrawstatus)
local _enabled      = false

local _STATUSLINE   = '%!v:lua.require("keystone.statusline").render()'

---@type string?
local _saved_statusline

---@class keystone.statusline.RenderOpts
---@field bufnr integer
---@field winid integer
---@field is_current boolean

---One statusline section, optionally owning its own lifecycle. Built-ins are
---registered exactly like user-provided ones; see `M.register`.
---
---  - `render`  section text, `""` to omit; an optional second return is the
---              compact variant the fit pass uses before dropping the section.
---  - `enable`  sets up state/autocmds; calls `on_change` when they change.
---  - `disable` tears down whatever `enable` set up.
---@class keystone.statusline.Provider
---@field render      fun(opts:keystone.statusline.RenderOpts): string, string?
---@field enable?     fun(on_change: fun())
---@field disable?    fun()

---A section is either the name of a registered provider or an inline function
---returning a statusline string (and, optionally, a short variant as a second
---return; see `Provider.render`).
---@alias keystone.statusline.Section string | fun(opts: keystone.statusline.RenderOpts): string, string?

---@class keystone.statusline.Sections
---@field left  keystone.statusline.Section[]
---@field right keystone.statusline.Section[]

---Section names ordered by priority, **most important first**; the least
---important give way first when the window is too narrow. Unlisted names rank
---below every listed one; inline function sections are never dropped.
---@alias keystone.statusline.Priority string[]
---
---@class keystone.statusline.Config
---@field enabled   boolean
---@field sections  keystone.statusline.Sections
---@field priority  keystone.statusline.Priority
---@field separator string  drawn between sections, in `KeystoneSLSep(NC)`

-- ---------------------------------------------------------------------------
-- Provider registry
-- ---------------------------------------------------------------------------

---@type table<string, keystone.statusline.Provider>
local _registry     = {}

---Names of providers whose `enable` hook is currently running, so `disable`
---tears down exactly those, not whatever `M.config.sections` says *now*,
---which may have already changed by the time `disable` runs (see `M.setup`).
---@type table<string, true>
local _active       = {}

---Sections already reported as failing, so a provider that throws on every
---redraw is only reported once. Cleared for a section when it is re-registered
---or when `M.setup` runs, giving a fixed provider a clean slate.
---@type table<keystone.statusline.Section, true>
local _warned       = {}

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

---The separator's groups, one per window state. Users override `…Sep` / `…SepNC`,
---which only *default*-link to `…SepDefault` / `…SepDefaultNC`, so their
---definitions win and survive the rebuild those get on every `ColorScheme`.
local _separator_hl   = "KeystoneSLSep"
local _separatorNC_hl = "KeystoneSLSepNC"

---A `%#Group#` attribute is *combined* with the window's base statusline group,
---so only the foreground needs overriding. The combine ORs in `reverse`, which
---draws a group's *background* as its foreground -- hence the field swap below.
---@param name string  the group to define
---@param base string  the statusline group it is drawn over
---@param src  vim.api.keyset.highlight  the highlight to take the foreground from
local function _def_separator(name, base, src)
  local base_hl = vim.api.nvim_get_hl(0, { name = base, link = false })
  local base_cterm = base_hl.cterm
  local hl = {} ---@type vim.api.keyset.highlight
  if base_hl.reverse then hl.bg = src.fg else hl.fg = src.fg end
  if base_cterm and base_cterm.reverse then hl.ctermbg = src.ctermfg else hl.ctermfg = src.ctermfg end
  vim.api.nvim_set_hl(0, name .. "Default", hl)
  vim.api.nvim_set_hl(0, name, { default = true, link = name .. "Default" })
end

local function _update_separator_hl()
  local src = vim.api.nvim_get_hl(0, { name = "NonText", link = false })
  _def_separator(_separator_hl, "StatusLine", src --[[@as vim.api.keyset.highlight]])
  _def_separator(_separatorNC_hl, "StatusLineNC", src --[[@as vim.api.keyset.highlight]])
end

---Register a section provider under `name` for use in `config.sections`; a bare
---function is treated as a render-only provider. May be called at any time: an
---already-enabled section's `enable` hook runs immediately.
---
---@param name     string
---@param provider keystone.statusline.Provider | fun(opts: keystone.statusline.RenderOpts): string
function M.register(name, provider)
  if type(provider) == "function" then
    provider = { render = provider }
  end
  assert(type(provider) == "table" and type(provider.render) == "function",
    "keystone.statusline: provider must have a `render` function")

  -- Replacing a live provider: whatever the outgoing one's `enable` set up is
  -- still running, and only that provider's own `disable` can tear it down.
  local previous = _registry[name]
  if previous and _active[name] then
    if previous.disable then previous.disable() end
    _active[name] = nil
  end

  _registry[name] = provider
  _warned[name] = nil
  if _enabled and _is_used(name) then
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
  _warned[name] = nil
end

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

---@type keystone.statusline.Config
local _default_config = {
  enabled = true,
  separator = "│",
  sections = {
    left  = { "mode", "filename", },
    right = { "lsp_progress", "diagnostics", "filetype", "position", },
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

---@type keystone.statusline.Config
M.config = vim.deepcopy(_default_config)

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
  return string.format("%%#%s#%s%%*", info.hl, info.label),
      string.format("%%#%s#%s%%*", info.hl, info.short)
end

--- Icons for buffers that have no file, and therefore no filetype icon, of
--- their own, keyed by `buftype`. Anything unlisted falls back to no icon.
local _BUFTYPE_ICONS = {
  terminal = "󰆍",
  help     = "󰘥",
  quickfix = "󰁨",
  prompt   = "󰘎",
  nofile   = "󰈔",
  acwrite  = "󰈔",
}

--- `fnamemodify(name, ":~:.")` costs ~11µs, more than every other section put
--- together, and only changes with the path or cwd. So it is cached by path and
--- dropped wholesale on `DirChanged`; keying by cwd would cost as much as it saves.
---@type table<string, string>
local _rel_cache = {}
local _rel_count = 0

local function _clear_rel_cache()
  _rel_cache, _rel_count = {}, 0
end

--- Path relative to the effective cwd, with `%` escaped for statusline syntax.
---@param name string
---@return string
local function _rel_path(name)
  local rel = _rel_cache[name]
  if rel then return rel end
  -- Bounded so a long-lived session that visits many files cannot grow it
  -- without limit; entries are cheap enough that wholesale reset beats an LRU.
  if _rel_count >= 512 then _clear_rel_cache() end
  rel = (vim.fn.fnamemodify(name, ":~:."):gsub("%%", "%%%%"))
  _rel_cache[name] = rel
  _rel_count = _rel_count + 1
  return rel
end

--- Full form is the path relative to cwd, short form the tail. Special buffers
--- get a `buftype` icon and, having no path to shorten, the same text for both:
--- a terminal's running command, otherwise the buffer name's tail.
---@param opts keystone.statusline.RenderOpts
---@return string full, string short
local function _section_filename(opts)
  local bufnr = opts.bufnr
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return "%*[No Name]", "%*[No Name]"
  end

  local buftype = vim.bo[bufnr].buftype
  local rel, tail, icon
  if buftype == "" then
    local filename = vim.fn.fnamemodify(name, ":t")
    rel            = _rel_path(name)
    tail           = filename:gsub("%%", "%%%%")
    icon           = icons.get_icon(filename)
  elseif buftype == "terminal" then
    -- `term://{cwd}//{pid}:{cmd}`: keep the command, drop the cwd and pid.
    tail = name:match("//%d+:(.+)$") or name:match("([^/\\]+)$") or name
    tail = tail:gsub("%%", "%%%%")
    rel  = tail
    icon = _BUFTYPE_ICONS.terminal
  else
    tail = name:match("([^/\\]+)$") or name
    if buftype == "help" then tail = tail:gsub("%.txt$", "") end
    tail = tail:gsub("%%", "%%%%")
    rel  = tail
    icon = _BUFTYPE_ICONS[buftype] or ""
  end
  local icon_str = (icon and icon ~= "") and (icon .. " ") or ""
  local mod      = vim.bo[bufnr].modified and " [+]" or ""
  local ro       = vim.bo[bufnr].readonly and " [ro]" or ""
  return string.format("%%*%s%s%s%s", icon_str, rel, mod, ro),
      string.format("%%*%s%s%s%s", icon_str, tail, mod, ro)
end

---@param opts keystone.statusline.RenderOpts
---@return string
local function _section_diagnostics(opts)
  local counts = vim.diagnostic.count(opts.bufnr)
  local e = counts[vim.diagnostic.severity.ERROR] or 0
  local w = counts[vim.diagnostic.severity.WARN] or 0
  local h = counts[vim.diagnostic.severity.HINT] or 0

  local parts = {}
  if e > 0 then parts[#parts + 1] = string.format("%%#KeystoneSLDiagError#󰅚 %d", e) end
  if w > 0 then parts[#parts + 1] = string.format("%%#KeystoneSLDiagWarn#󰀪 %d", w) end
  if h > 0 then parts[#parts + 1] = string.format("%%#KeystoneSLDiagHint#󰋽 %d", h) end
  if #parts == 0 then return "" end

  return table.concat(parts, " ") .. "%*"
end

---@param opts keystone.statusline.RenderOpts
---@return string
local function _section_filetype(opts)
  local bufnr = opts.bufnr
  if vim.bo[bufnr].buftype ~= "" then return "" end
  local ft = vim.bo[bufnr].filetype
  if ft == "" then return "" end
  return "%*" .. ft
end

---@return string
local function _section_position(_)
  return "%*%4l:%-3c"
end

---Register the built-in sections through the same public registry users use.
local function _register_builtins()
  M.register("mode", {
    enable = function()
      local hls = {
        KeystoneSLModeNormal  = { default = true, fg = "#6E94C9", bold = true },
        KeystoneSLModeInsert  = { default = true, fg = "#7BA87A", bold = true },
        KeystoneSLModeVisual  = { default = true, fg = "#9D82C7", bold = true },
        KeystoneSLModeReplace = { default = true, fg = "#B87A90", bold = true },
        KeystoneSLModeCommand = { default = true, fg = "#CDCDCD", bold = true },
      }
      for n, hl in pairs(hls) do vim.api.nvim_set_hl(0, n, hl) end
    end,
    render = _section_mode,
  })
  M.register("filename", _section_filename)
  M.register("diagnostics", {
    enable = function()
      local hls = {
        KeystoneSLDiagError = { default = true, link = "DiagnosticError" },
        KeystoneSLDiagWarn  = { default = true, link = "DiagnosticWarn" },
        KeystoneSLDiagHint  = { default = true, link = "DiagnosticHint" },
      }
      for n, hl in pairs(hls) do vim.api.nvim_set_hl(0, n, hl) end
    end,
    render = _section_diagnostics,
  })
  M.register("filetype", _section_filetype)
  M.register("position", _section_position)
  M.register("git", require("keystone.statusline.git"))
  M.register("lsp_progress", require("keystone.statusline.lsp_progress"))
  M.register("symbol_path", require("keystone.statusline.symbol_path"))
end

_register_builtins()

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

-- name -> rank lookup, rebuilt only when the priority list itself changes:
-- `M.setup` assigns a fresh table, and an in-place edit shows up as a length
-- change.
local _rank_map
local _rank_map_src
local _rank_map_len

---@return table<string, integer> name -> 1-based rank (lower is more important)
local function _rank_lookup()
  local priority = M.config.priority
  -- Length is checked alongside identity so the common in-place mutations
  -- (`table.insert`/`table.remove` on the live config) are not missed.
  if _rank_map_src ~= priority or _rank_map_len ~= #priority then
    _rank_map = {}
    for i, name in ipairs(priority) do
      if _rank_map[name] == nil then _rank_map[name] = i end
    end
    _rank_map_src = priority
    _rank_map_len = #priority
  end
  return _rank_map
end

---Priority rank: the 1-based index in `config.priority` (lower is dropped last).
---Unlisted names share the rank one past its end, ranking after every listed one.
---Inline functions cannot be named, so they rank `nil` and are never dropped.
---@param section keystone.statusline.Section
---@return integer?
local function _rank(section)
  if type(section) ~= "string" then return nil end
  return _rank_lookup()[section] or #M.config.priority + 1
end

---Render one section, keeping a provider that throws from taking the statusline
---down with it. Reported once, since such a section errors on every redraw, and
---omitted until it renders cleanly.
---@param render fun(opts: keystone.statusline.RenderOpts): string?, string?
---@param id     keystone.statusline.Section  the section, for reporting
---@param render_opts keystone.statusline.RenderOpts
---@return string? text, string? short
local function _safe_render(render, id, render_opts)
  local ok, text, short = pcall(render, render_opts)
  if ok then return text, short end
  if not _warned[id] then
    _warned[id] = true
    local msg = ("keystone.statusline: section %s failed to render: %s")
        :format(type(id) == "string" and ("'" .. id .. "'") or "<function>", text)
    -- Deferred: a statusline is evaluated in contexts where `nvim_echo` and
    -- friends are not allowed to run.
    vim.schedule(function() vim.notify(msg, vim.log.levels.ERROR) end)
  end
  return nil, nil
end

---Render each section once and measure its display width. Widths are additive --
---highlight/field syntax is zero- or fixed-width regardless of neighbours -- so
---the fit pass can sum and subtract them without re-measuring.
---@param section_list keystone.statusline.Section[]
---@param render_opts keystone.statusline.RenderOpts
---@return keystone.statusline._Entry[]
local function _build_entries(section_list, render_opts)
  local entries = {}
  local winid = render_opts.winid
  for _, section in ipairs(section_list) do
    ---@type string?, string?
    local text, short
    if type(section) == "function" then
      text, short = _safe_render(section, section, render_opts)
    elseif type(section) == "string" then
      local provider = _registry[section]
      if provider then text, short = _safe_render(provider.render, section, render_opts) end
    end
    if text and text ~= "" then
      local width = vim.api.nvim_eval_statusline(text, { winid = winid }).width
      -- Text that renders to nothing visible (highlight syntax only) would
      -- otherwise claim a slot, and with it a separator with nothing beside it.
      if width > 0 then
        -- A section with no shorter form reuses its full text/width.
        local short_text, short_width = text, width
        if short and short ~= "" and short ~= text then
          short_text  = short
          short_width = vim.api.nvim_eval_statusline(short, { winid = winid }).width
        end
        entries[#entries + 1] = {
          text        = text,
          width       = width,
          short_text  = short_text,
          short_width = short_width,
          rank        = _rank(section),
          shown       = true,
        }
      end
    end
  end
  return entries
end

---The separator glyph in its own highlight, for use on its own between the two
---groups.
---@param is_current boolean
---@return string
local function _separator_glyph(is_current)
  local hl = is_current and _separator_hl or _separatorNC_hl
  return string.format("%%#%s#%s%%*", hl, M.config.separator)
end

---The separator string drawn between adjacent sections, in the separator
---highlight, flanked by a space on each side. Sections themselves emit no
---surrounding padding; spacing lives here so it is uniform and configurable.
---@param is_current boolean
---@return string
local function _separator(is_current)
  return string.format(" %s ", _separator_glyph(is_current))
end

---Join the shown entries with `sep`, adding one space of edge padding on each
---side of a non-empty group.
---@param entries keystone.statusline._Entry[]
---@param sep     string
---@return string
local function _concat_shown(entries, sep)
  local parts = {}
  for _, entry in ipairs(entries) do
    if entry.shown then parts[#parts + 1] = entry.text end
  end
  if #parts == 0 then return "" end
  return string.format(" %s ", table.concat(parts, sep))
end

---One side's running totals: the summed width and count of its shown entries.
---The fit passes keep these up to date as they shrink and hide sections, so the
---combined statusline width stays O(1) to recompute.
---@class keystone.statusline._Group
---@field entries keystone.statusline._Entry[]
---@field width   integer sum of the shown entries' widths
---@field shown   integer number of shown entries

---@param entries keystone.statusline._Entry[]
---@return keystone.statusline._Group
local function _group(entries)
  local group = { entries = entries, width = 0, shown = 0 }
  for _, entry in ipairs(entries) do
    if entry.shown then
      group.width = group.width + entry.width
      group.shown = group.shown + 1
    end
  end
  return group
end

---Combined rendered width of both groups: their shown sections, one separator
---between each adjacent pair, plus a space of edge padding on each side of a
---non-empty group. O(1): it only reads the running totals.
---@param groups keystone.statusline._Group[]
---@param sep_w  integer display width of one separator
---@return integer
local function _width(groups, sep_w)
  local total = 0
  for _, group in ipairs(groups) do
    if group.shown > 0 then
      total = total + group.width + (group.shown - 1) * sep_w + 2
    end
  end
  return total
end

---The order sections give way in: least important first, later first among equal
---ranks; unranked inline functions never appear. Ranks are small integers, so one
---bucket pass over just the range present orders them with no sort.
---@param groups keystone.statusline._Group[]
---@return keystone.statusline._Entry[]                                 order
---@return table<keystone.statusline._Entry, keystone.statusline._Group> group_of
local function _drop_order(groups)
  ---@type table<integer, keystone.statusline._Entry[]>
  local buckets = {}
  ---@type table<keystone.statusline._Entry, keystone.statusline._Group>
  local group_of = {}
  local lowest, highest

  for _, group in ipairs(groups) do
    for _, entry in ipairs(group.entries) do
      local rank = entry.rank
      if rank then
        group_of[entry]     = group
        local bucket        = buckets[rank] or {}
        buckets[rank]       = bucket
        bucket[#bucket + 1] = entry
        if not lowest or rank < lowest then lowest = rank end
        if not highest or rank > highest then highest = rank end
      end
    end
  end

  local order = {}
  for rank = highest or 0, lowest or 1, -1 do
    local bucket = buckets[rank]
    if bucket then
      for i = #bucket, 1, -1 do
        order[#order + 1] = bucket[i]
      end
    end
  end
  return order, group_of
end

---Shrink into `budget` columns in two passes over the drop order: switch to short
---variants, then hide outright, stopping as soon as it fits. Works purely on the
---pre-measured widths and running totals, so both passes are O(n).
---@param left    keystone.statusline._Entry[]
---@param right   keystone.statusline._Entry[]
---@param budget  integer columns the two groups together may occupy
---@param sep_w   integer display width of one separator
---@return integer used  final combined width of both groups
local function _fit(left, right, budget, sep_w)
  local groups = { _group(left), _group(right) }
  local used   = _width(groups, sep_w)
  if used <= budget then return used end

  local order, group_of = _drop_order(groups)

  -- Pass 1: shrink to short variants; only the entry's own width changes.
  -- Sections with no shorter form would be a no-op, so they are stepped over
  -- rather than re-measured.
  for _, entry in ipairs(order) do
    if entry.width ~= entry.short_width then
      local group = group_of[entry]
      group.width = group.width - (entry.width - entry.short_width)
      entry.text, entry.width = entry.short_text, entry.short_width
      used = _width(groups, sep_w)
      if used <= budget then return used end
    end
  end

  -- Pass 2: hide outright; the group loses both the width and the shown slot,
  -- and with it either a separator or, when it was the last one, its padding.
  for _, entry in ipairs(order) do
    local group = group_of[entry]
    group.width = group.width - entry.width
    group.shown = group.shown - 1
    entry.shown = false
    used = _width(groups, sep_w)
    if used <= budget then return used end
  end

  return used
end

---@return string
local function _render()
  local winid = vim.g.statusline_winid
  if not winid or winid == 0 then
    winid = vim.api.nvim_get_current_win()
  end
  if not vim.api.nvim_win_is_valid(winid) then return "" end

  -- With `laststatus=3` one statusline spans the screen, drawn for whichever
  -- window is current -- including floats, which have none of their own, and
  -- splits, whose width says nothing about the room the line actually has.
  local global = vim.o.laststatus == 3
  if not global and vim.api.nvim_win_get_config(winid).relative ~= "" then
    return ""
  end
  local win_width   = global and vim.o.columns or vim.api.nvim_win_get_width(winid)
  local bufnr       = vim.api.nvim_win_get_buf(winid)

  local is_current  = vim.api.nvim_get_current_win() == winid
  local render_opts = { ---@type keystone.statusline.RenderOpts
    bufnr = bufnr,
    winid = winid,
    is_current = is_current,
  }

  local secs        = M.config.sections
  local left        = _build_entries(secs.left, render_opts)
  local right       = _build_entries(secs.right, render_opts)

  local sep         = _separator(is_current)
  local sep_w       = vim.api.nvim_eval_statusline(sep, { winid = winid }).width

  -- The gap must hold the separator glyph: the groups already contribute a space
  -- of padding each, so only the glyph's own width is held back, and only when
  -- two groups could actually meet -- otherwise a section is dropped a column early.
  local glyph_w     = sep_w - 2
  local reserve     = (#left > 0 and #right > 0) and glyph_w or 0
  local budget      = win_width - reserve
  local used        = _fit(left, right, budget, sep_w)

  local ltext       = _concat_shown(left, sep)
  local rtext       = _concat_shown(right, sep)

  -- Touching groups get a separator between them, like adjacent sections within
  -- one; `%=` then expands to nothing. Skipped when even the fully-shrunk line
  -- overflows, where the glyph has nowhere to go and only adds to it.
  local mid         = ""
  if used <= budget and ltext ~= "" and rtext ~= "" and win_width - used <= glyph_w then
    mid = _separator_glyph(is_current)
  end

  return string.format("%s%s%%=%s", ltext, mid, rtext)
end

function M.render()
  -- Each section's own render is already isolated, but malformed statusline
  -- syntax coming out of one can still make `nvim_eval_statusline` throw, and a
  -- broken section must not be able to break the editor's redraw.
  local ok, result = pcall(_render)
  return ok and result or ""
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

---Bring the running providers in line with the current config: tear down the
---ones no longer referenced, start the ones that just became referenced, and
---leave the rest untouched so a reconfigure does not disturb their state.
local function _sync_active()
  for name in pairs(_active) do
    if not _is_used(name) then
      local provider = _registry[name]
      if provider and provider.disable then provider.disable() end
      _active[name] = nil
    end
  end
  for name, provider in pairs(_registry) do
    if not _active[name] and _is_used(name) then
      _active[name] = true
      if provider.enable then provider.enable(_redrawstatus) end
    end
  end
end

function M.enable()
  if _enabled then return end
  _enabled = true

  _update_separator_hl()

  -- Never save our own expression over the real previous value, or a stray
  -- `enable` would make the restore in `M.disable` a no-op.
  local current = vim.o.statusline
  if current ~= _STATUSLINE then _saved_statusline = current end
  vim.o.statusline = _STATUSLINE

  _sync_active()

  local group = vim.api.nvim_create_augroup("keystone_statusline", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = _update_separator_hl,
  })
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    pattern = "*",
    callback = _clear_rel_cache,
  })
  _clear_rel_cache()
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
  _clear_rel_cache()
  vim.o.statusline = _saved_statusline or ""
  _saved_statusline = nil
end

local _setup = false

--- A fresh copy of the module defaults, as `setup()` starts from. Safe to mutate.
---@return table
function M.get_default_config()
  return vim.deepcopy(_default_config)
end

--- Whether `setup()` has been called for this module.
---@return boolean
function M.is_setup()
  return _setup
end

---@param opts keystone.statusline.Config?
function M.setup(opts)
  _setup = true
  cfgutil.apply(M.config, _default_config, opts)
  _warned = {}
  if not M.config.enabled then
    M.disable()
  elseif _enabled then
    _update_separator_hl()
    _sync_active()
  else
    M.enable()
  end
end

return M
