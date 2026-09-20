local M = {}

local cfgutil = require("keystone.util.config")

-- ---------------------------------------------------------------------------
-- Scope
--
-- Draws a guide along the scope under the cursor and, optionally, indent guides
-- on every level. Both are ephemeral extmarks set from a decoration provider,
-- so only the visible lines are ever computed and nothing is stored in buffers.
--
-- The scope comes from Treesitter and needs the buffer to have highlighting
-- active (the tree is then kept parsed by the highlighter): the smallest node
-- around the cursor whose body is indented deeper than its first line. A
-- cursor on a header line (`function f()`, `if x then`) selects the body below
-- it. Without highlighting there is no scope.
--
-- Only the current window shows a scope. It is recomputed on cursor moves,
-- edits and reparses, and when it changes the window is asked to redraw the
-- rows involved, since a cursor move alone does not redraw anything.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

local _HL_SCOPE = "KeystoneScope"
local _HL_GUIDE = "KeystoneIndentGuide"

-- Variants of the groups above, drawn with instead of them while a blend is
-- configured; see `_setup_highlights`.
local _HL_SCOPE_BLEND = "KeystoneScopeBlend"
local _HL_GUIDE_BLEND = "KeystoneIndentGuideBlend"

vim.api.nvim_set_hl(0, _HL_SCOPE, { default = true, link = "NonText" })
vim.api.nvim_set_hl(0, _HL_GUIDE, { default = true, link = _HL_SCOPE })

---@class keystone.scope.Config
---@field enabled boolean? master switch; when false nothing is drawn
---@field scope boolean? draw a guide along the scope under the cursor
---@field guides boolean? draw a guide on every indent level
---@field scope_char string? character of the scope guide (one cell wide)
---@field guide_char string? character of the indent guides (one cell wide)
---@field scope_blend integer? percent the scope guide fades into the background, 0-100
---@field guide_blend integer? percent the indent guides fade into the background, 0-100
---@field exclude_filetypes string[]? filetypes left alone

---@type keystone.scope.Config
local _default_config = {
  enabled           = true,
  scope             = true,
  guides            = true,
  scope_char        = "┃",
  guide_char        = "│",
  scope_blend       = 25,
  guide_blend       = 50,
  exclude_filetypes = { "help", "markdown", "text", "gitcommit", "man", "checkhealth", "qf" },
}

---@type keystone.scope.Config
M.config = vim.deepcopy(_default_config)

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local _NS = vim.api.nvim_create_namespace("keystone.scope")
local _AUGROUP = "keystone.scope"

-- Lines scanned in each direction when inferring a blank line's indent or
-- building the guide stack; bounds the cost on huge files.
local _MAX_SCAN = 1000

-- Lines read per call once a walk leaves the rows read up front.
local _CHUNK = 32

local _enabled = false

---@type table<string, true>
local _excluded = {}

---@class keystone.scope.Scope
---@field buf integer
---@field tick integer changedtick it was computed at
---@field row integer 0-based cursor row it was computed for
---@field tree TSTree? syntax tree it was found in
---@field col integer? display column of the guide; nil when there is no scope
---@field first integer? 0-based first row of the body
---@field last integer? 0-based last row of the body

-- Scope of the current window, keyed by window.
---@type table<integer, keystone.scope.Scope>
local _scopes = {}

-- Whether `_on_end` has an update scheduled.
local _update_pending = false

-- ---------------------------------------------------------------------------
-- Indentation
-- ---------------------------------------------------------------------------

--- Display width of the leading whitespace of `line`, and whether the text
--- after it starts with `leader`; nil when it is blank.
---@param line string
---@param ts integer tabstop
---@param leader string? comment leader
---@return integer?, boolean?
local function _indent_of(line, ts, leader)
  local w = 0
  for i = 1, #line do
    local b = line:byte(i)
    if b == 32 then
      w = w + 1
    elseif b == 9 then
      w = w + ts - w % ts
    else
      return w, leader ~= nil and line:sub(i, i + #leader - 1) == leader
    end
  end
  return nil
end

--- Indent of a row, nil when it is blank, and whether it is a comment.
---@alias keystone.scope.IndentFn fun(row: integer): integer?, boolean?

--- Indents of a `_CHUNK`-line block: false for blank lines, nil past the end.
---@class keystone.scope.Chunk
---@field [integer] integer|false
---@field comments table<integer, true>

---@class keystone.scope.Indents
---@field ts integer
---@field leader string?
---@field chunks table<integer, keystone.scope.Chunk> keyed by first row
---@field fn keystone.scope.IndentFn

-- Indent readers, keyed by buffer; kept across edits, which only drop the
-- blocks they touch, and dropped when 'tabstop' or 'commentstring' changes or
-- the buffer is hidden.
---@type table<integer, keystone.scope.Indents>
local _indents = {}

-- Buffers whose changes are watched to invalidate `_indents`.
---@type table<integer, true>
local _attached = {}

--- A memoizing reader of line indents for `buf`: a row is read along with the
--- rest of its `_CHUNK`-line block. Comments are the lines starting with the
--- leader of 'commentstring'.
---@param buf integer
---@param ts integer tabstop
---@param leader string? comment leader
---@param chunks table<integer, keystone.scope.Chunk>
---@return keystone.scope.IndentFn
local function _indent_reader(buf, ts, leader, chunks)
  return function(row)
    local base = row - row % _CHUNK
    local chunk = chunks[base]
    if not chunk then
      chunk = { comments = {} }
      for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, base, base + _CHUNK, false)) do
        local w, comment = _indent_of(line, ts, leader)
        chunk[i] = w or false
        if comment then chunk.comments[i] = true end
      end
      chunks[base] = chunk
    end
    local i = row - base + 1
    return chunk[i] or nil, chunk.comments[i]
  end
end

--- Drop the cached indents of the rows changed in `buf`: from `first` to
--- `last` (exclusive) when the line count holds, else every row from `first`.
---@param buf integer
---@param first integer
---@param last integer
---@param last_new integer
local function _on_lines(_, buf, _, first, last, last_new)
  if not _enabled then
    _attached[buf] = nil
    return true
  end
  local cached = _indents[buf]
  if not cached then return end
  local chunks = cached.chunks
  if last == last_new then
    for base = first - first % _CHUNK, last - 1, _CHUNK do chunks[base] = nil end
  else
    for base in pairs(chunks) do
      if base + _CHUNK > first then chunks[base] = nil end
    end
  end
end

---@param buf integer
local function _on_reload(_, buf)
  _indents[buf] = nil
end

---@param buf integer
local function _on_detach(_, buf)
  _attached[buf] = nil
  _indents[buf] = nil
end

--- The indent reader of `buf` for its current text and options.
---@param buf integer
---@return keystone.scope.IndentFn
local function _indent(buf)
  local ts = vim.api.nvim_get_option_value("tabstop", { buf = buf })
  local leader = vim.api.nvim_get_option_value("commentstring", { buf = buf }):match("^%s*(.-)%s*%%s")
  if leader == "" then leader = nil end
  local cached = _indents[buf]
  if cached and cached.ts == ts and cached.leader == leader then
    return cached.fn
  end
  if not _attached[buf] then
    _attached[buf] = true
    vim.api.nvim_buf_attach(buf, false, {
      on_lines  = _on_lines,
      on_reload = _on_reload,
      on_detach = _on_detach,
    })
  end
  local chunks = {}
  local fn = _indent_reader(buf, ts, leader, chunks)
  _indents[buf] = { ts = ts, leader = leader, chunks = chunks, fn = fn }
  return fn
end

--- Indent of `row`, nil when it is blank or a comment: comments may sit left
--- of the code around them and so tell nothing about the structure.
---@param indent keystone.scope.IndentFn
---@param row integer
---@return integer?
local function _code_indent(indent, row)
  local v, comment = indent(row)
  if not comment then return v end
end

--- Indent of `row`; a blank line takes its nearest code neighbours' indents
--- combined with `pick`, a comment at least that.
---@param indent keystone.scope.IndentFn
---@param row integer
---@param last_row integer
---@param pick fun(a: integer, b: integer): integer
---@return integer
local function _inferred(indent, row, last_row, pick)
  local v, comment = indent(row)
  if v and not comment then return v end
  local up, down
  for r = row - 1, math.max(0, row - _MAX_SCAN), -1 do
    up = _code_indent(indent, r)
    if up then break end
  end
  for r = row + 1, math.min(last_row, row + _MAX_SCAN) do
    down = _code_indent(indent, r)
    if down then break end
  end
  local around = up and down and pick(up, down) or up or down or 0
  return v and math.max(v, around) or around
end

--- Advance the guide stack past the code line `row`, indented `ind`. A line
--- shallower than the one before closes the deeper levels, unless the next
--- non-blank line resumes one of them: such a line (a preprocessor directive,
--- a label) leaves the stack alone. Only the next line counts, or a closing
--- line followed by a new block (`end`, then `function f()`) would resume.
---@param stack integer[]
---@param indent keystone.scope.IndentFn
---@param row integer
---@param ind integer
---@param last_row integer
local function _step(stack, indent, row, ind, last_row)
  local top = stack[#stack]
  if top and top > ind then
    for r = row + 1, math.min(last_row, row + _MAX_SCAN) do
      local v = _code_indent(indent, r)
      if v then
        if v > ind then
          -- Inline: `vim.list_contains` validates its arguments on every call.
          for _, c in ipairs(stack) do
            if c == v then return end
          end
        end
        break
      end
    end
  end
  while #stack > 0 and stack[#stack] >= ind do stack[#stack] = nil end
  stack[#stack + 1] = ind
end

--- Guide stack as it stands just before `row`: indents of the enclosing lines,
--- outermost first. Built forward from the nearest pair of consecutive
--- unindented code lines above, which enclose nothing.
---@param indent keystone.scope.IndentFn
---@param row integer
---@param last_row integer
---@return integer[]
local function _enclosing(indent, row, last_row)
  local start = math.max(0, row - _MAX_SCAN)
  local below = _code_indent(indent, row)
  for r = row - 1, start, -1 do
    local v = _code_indent(indent, r)
    if v then
      if v == 0 and below == 0 then
        start = r
        break
      end
      below = v
    end
  end
  local stack = {}
  for r = start, row - 1 do
    local v = _code_indent(indent, r)
    if v then _step(stack, indent, r, v, last_row) end
  end
  return stack
end

-- ---------------------------------------------------------------------------
-- Scope detection
-- ---------------------------------------------------------------------------

--- Scope from the Treesitter node around `row`: the smallest ancestor spanning
--- several lines whose body is indented deeper than its first line. The last
--- line belongs to the body unless it is a closing line (`end`, `}`) at or
--- left of the header's indent.
---@param buf integer
---@param parser vim.treesitter.LanguageTree
---@param row integer
---@param indent keystone.scope.IndentFn
---@param last_row integer
---@return integer? col, integer? first, integer? last
local function _ts_scope(buf, parser, row, indent, last_row)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local col = (line:find("%S") or 1) - 1
  local innermost = parser:named_node_for_range({ row, col, row, col })
  if not innermost then return end

  -- Ancestors, root first. Built top-down: `parent()` walks from the root on
  -- every call, which makes a bottom-up walk quadratic in the depth.
  local chain = { innermost:tree():root() }
  while chain[#chain] ~= innermost do
    local child = chain[#chain]:child_with_descendant(innermost)
    if not child then break end
    chain[#chain + 1] = child
  end

  ---@type table<integer, integer>
  local inferred = {}
  -- The root has no header.
  for i = #chain, 2, -1 do
    local node = chain[i]
    local s, _, e, ecol = node:range()
    if ecol == 0 and e > s then e = e - 1 end

    local hdr = indent(s)
    if hdr and e > s then
      local last = e
      local tail = indent(e)
      if not tail or tail <= hdr then last = e - 1 end
      -- A cursor on the closing line only belongs to the node that owns it.
      local inside = row <= last or node == innermost
      if last > s and inside then
        -- Mostly `row` itself: nested nodes share the probe.
        local probe = math.min(math.max(row, s + 1), last)
        local level = inferred[probe] or _inferred(indent, probe, last_row, math.max)
        inferred[probe] = level
        if level > hdr then
          return hdr, s + 1, last
        end
      end
    end
  end
end

---@param buf integer
---@return boolean
local function _is_eligible(buf)
  -- Called on every redraw: `vim.bo[buf]` allocates on each access.
  return vim.api.nvim_get_option_value("buftype", { buf = buf }) == ""
      and not _excluded[vim.api.nvim_get_option_value("filetype", { buf = buf })]
end

--- Parser of the Treesitter highlighter of `buf`, if any.
---@param buf integer
---@return vim.treesitter.LanguageTree?
local function _ts_parser(buf)
  local active = vim.treesitter.highlighter.active[buf]
  return active and active.tree or nil
end

--- Whether `scope` still holds in `win`: same buffer, text and cursor row, and
--- no newer syntax tree. The highlighter reparses during redraw, after the
--- autocmds that compute the scope.
---@param scope keystone.scope.Scope
---@param win integer
---@param buf integer buffer of `win`
---@return boolean
local function _is_current(scope, win, buf)
  if scope.buf ~= buf or scope.tick ~= vim.api.nvim_buf_get_changedtick(buf)
      or scope.row ~= vim.api.nvim_win_get_cursor(win)[1] - 1 then
    return false
  end
  local parser = _ts_parser(buf)
  return scope.tree == (parser and parser:trees()[1])
end

--- Compute the scope for the cursor of `win`.
---@param win integer
---@return keystone.scope.Scope
local function _compute(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local row = vim.api.nvim_win_get_cursor(win)[1] - 1
  local parser = _ts_parser(buf)
  ---@type keystone.scope.Scope
  local scope = {
    buf  = buf,
    tick = vim.api.nvim_buf_get_changedtick(buf),
    row  = row,
    tree = parser and parser:trees()[1],
  }
  if not (parser and M.config.scope and _is_eligible(buf)) then return scope end

  local last_row = vim.api.nvim_buf_line_count(buf) - 1
  scope.col, scope.first, scope.last = _ts_scope(buf, parser, row, _indent(buf), last_row)
  return scope
end

---@param a keystone.scope.Scope?
---@param b keystone.scope.Scope?
---@return boolean
local function _same_range(a, b)
  a, b = a or {}, b or {}
  return a.buf == b.buf and a.col == b.col and a.first == b.first and a.last == b.last
end

--- Ask for the rows of `win` covered by either scope to be redrawn at the next
--- screen update. Not forced: a forced update from a cursor autocmd draws a
--- frame of its own, and a smooth-scroll plugin scrolls by jumping to the
--- destination and animating back from where it started, so that frame shows
--- the destination the scroll is about to rewind past.
---@param win integer
---@param old keystone.scope.Scope?
---@param new keystone.scope.Scope?
local function _redraw(win, old, new)
  if not vim.api.nvim_win_is_valid(win) then return end
  local first, last ---@type number,number
  for _, s in ipairs({ old or {}, new or {} }) do
    if s.first and s.buf == vim.api.nvim_win_get_buf(win) then
      first = math.min(first or s.first, s.first)
      last = math.max(last or s.last, s.last)
    end
  end
  if first then
    vim.api.nvim__redraw({ win = win, range = { first, last + 1 }, flush = false })
  end
end

--- Recompute the scope of `win` and redraw what changed.
---@param win integer
local function _update(win)
  local old = _scopes[win]
  local buf = vim.api.nvim_win_get_buf(win)
  if old and _is_current(old, win, buf) then return end
  -- After an edit the tree is reparsed at the next redraw, which recomputes
  -- the scope from `_on_win`; a scope found now would come from a stale tree.
  local parser = _ts_parser(buf)
  if parser and not parser:is_valid(true) then return end
  local new = _compute(win)
  _scopes[win] = new
  if not _same_range(old, new) then _redraw(win, old, new) end
end

---@param win integer
local function _clear(win)
  local old = _scopes[win]
  _scopes[win] = nil
  _redraw(win, old, nil)
end

-- ---------------------------------------------------------------------------
-- Highlights
-- ---------------------------------------------------------------------------

--- `fg` mixed `pct` percent of the way to `bg`, all 24-bit colours.
---@param fg integer
---@param bg integer
---@param pct integer
---@return integer
local function _mix(fg, bg, pct)
  local out = 0
  for _, scale in ipairs({ 65536, 256, 1 }) do
    local f, b = math.floor(fg / scale) % 256, math.floor(bg / scale) % 256
    out = out + math.floor(f + (b - f) * pct / 100 + 0.5) * scale
  end
  return out
end

--- The background the guides fade into: the one of `Normal`, or the darkest or
--- lightest the terminal can show when it has none.
---@return integer
local function _backdrop()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  return normal.bg or (vim.o.background == "light" and 0xffffff or 0x000000)
end

--- Define `dst` as the foreground of `src` faded `pct` percent into the
--- background. Only the foreground is taken: a guide is a single cell of
--- virtual text, so a background of the source's would paint a block behind
--- every one of them, and `NonText`, the default source, carries one in some
--- colorschemes. `ctermfg` comes over unfaded, there being no 24-bit colour to
--- fade there. `dst` links to `src` when it has no foreground at all, so the
--- guides are always drawn with `dst`.
---@param src string
---@param dst string
---@param pct integer
local function _blended(src, dst, pct)
  -- Resolved rather than followed by hand: `src` links to `NonText` by default.
  local hl = vim.api.nvim_get_hl(0, { name = src, link = false })
  if not (hl.fg or hl.ctermfg) then
    vim.api.nvim_set_hl(0, dst, { link = src })
    return
  end
  vim.api.nvim_set_hl(0, dst, {
    fg = hl.fg and _mix(hl.fg, _backdrop(), math.min(pct, 100)) or nil,
    ctermfg = hl.ctermfg,
  })
end

--- Pick the groups the guides are drawn with, defining the blended variants
--- from the current colours. Run on enable and on every colorscheme change,
--- since a new scheme redefines both the sources and the backdrop.
local function _setup_highlights()
  _blended(_HL_SCOPE, _HL_SCOPE_BLEND, M.config.scope_blend)
  _blended(_HL_GUIDE, _HL_GUIDE_BLEND, M.config.guide_blend)
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- Extmark options, reused for every mark: `_on_win` sets one per guide cell.
local _mark_opts = { hl_mode = "combine", ephemeral = true }

---@param buf integer
---@param row integer
---@param wincol integer
---@param virt_text table
---@param priority integer
local function _mark(buf, row, wincol, virt_text, priority)
  _mark_opts.virt_text = virt_text
  _mark_opts.virt_text_win_col = wincol
  _mark_opts.priority = priority
  vim.api.nvim_buf_set_extmark(buf, _NS, row, 0, _mark_opts)
end

---@param win integer
---@param buf integer
---@param toprow integer
---@param botrow integer
---@return boolean? false to skip the window
local function _on_win(_, win, buf, toprow, botrow)
  local config = M.config
  local current = config.scope and win == vim.api.nvim_get_current_win()
  if not (config.guides or current) or not _is_eligible(buf) then return false end

  ---@type keystone.scope.Scope?
  local scope
  if current then
    local old = _scopes[win]
    if old and _is_current(old, win, buf) then
      scope = old
    else
      local new = _compute(win)
      _scopes[win] = new
      -- Rows outside this redraw may still show the old scope.
      if not _same_range(old, new) then
        vim.schedule(function() _redraw(win, old, new) end)
      end
      scope = new
    end
    if not scope.col then scope = nil end
  end
  if not (config.guides or scope) then return false end

  local last_row = vim.api.nvim_buf_line_count(buf) - 1
  botrow = math.min(botrow, last_row)
  if scope and not config.guides then
    -- Only the scope's rows get a mark.
    toprow, botrow = math.max(toprow, scope.first), math.min(botrow, scope.last)
    if toprow > botrow then return false end
  end
  local indent = _indent(buf)

  -- Guides sit at the indents of the enclosing lines, the same columns a
  -- scope is drawn at, rather than at multiples of 'shiftwidth'.
  local stack = config.guides and _enclosing(indent, toprow, last_row) or {}

  local folds = vim.api.nvim_get_option_value("foldenable", { win = win })
  local guide_text = { { config.guide_char, _HL_GUIDE_BLEND } }
  local scope_text = { { config.scope_char, _HL_SCOPE_BLEND } }

  vim.api.nvim_win_call(win, function()
    local leftcol = vim.fn.winsaveview().leftcol
    -- Inferred level of the current run of blank lines; the same for all of
    -- them, as they share their nearest non-blank neighbours.
    local blank_level ---@type integer?
    local row = toprow
    while row <= botrow do
      local fold_end = folds and vim.fn.foldclosedend(row + 1) or -1
      if fold_end ~= -1 then
        blank_level = nil
        if config.guides then
          -- Step through the fold, only its head and tail when large: the
          -- head holds its header, the tail the levels open at its end.
          local half = _MAX_SCAN / 2
          local skip_from, skip_to = row + half, fold_end - half
          local r = row
          while r < fold_end do
            if r == skip_from and skip_to > skip_from then r = skip_to end
            local v = _code_indent(indent, r)
            if v then _step(stack, indent, r, v, last_row) end
            r = r + 1
          end
        end
        row = fold_end
      else
        local ind, comment = indent(row)
        local blank = ind == nil
        local in_scope = scope and row >= scope.first and row <= scope.last
            and (blank or ind > scope.col)

        if config.guides then
          local level = ind
          if ind then
            blank_level = nil
            if not comment then _step(stack, indent, row, ind, last_row) end
          else
            blank_level = blank_level or _inferred(indent, row, last_row, math.max)
            level = blank_level
          end
          for _, c in ipairs(stack) do
            if c >= level then break end
            if c >= leftcol and not (in_scope and scope and c == scope.col) then
              _mark(buf, row, c - leftcol, guide_text, 1)
            end
          end
        end
        if in_scope and scope and scope.col >= leftcol then
          _mark(buf, row, scope.col - leftcol, scope_text, 2)
        end
        row = row + 1
      end
    end
  end)
  return false
end

--- A tree reparsed after `_on_win` ran, by a decoration provider called later
--- in the same redraw, leaves the scope stale: recompute it afterwards.
local function _on_end()
  if _update_pending then return end
  local win = vim.api.nvim_get_current_win()
  local scope = _scopes[win]
  if not scope then return end
  local buf = vim.api.nvim_win_get_buf(win)
  -- An ineligible buffer never has a scope; skip terminals ticking on output.
  if _is_eligible(buf) and not _is_current(scope, win, buf) then
    _update_pending = true
    vim.schedule(function()
      _update_pending = false
      if _enabled and win == vim.api.nvim_get_current_win() then _update(win) end
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- The scope for `win` (defaults to the current window), with 1-based
--- rows, or nil when there is none.
---@param win integer?
---@return { col: integer, first: integer, last: integer }?
function M.get(win)
  win = win or vim.api.nvim_get_current_win()
  local scope = _compute(win)
  if not scope.col then return nil end
  return { col = scope.col, first = scope.first + 1, last = scope.last + 1 }
end

---@return boolean
function M.is_enabled()
  return _enabled
end

function M.enable()
  _enabled = true
  _excluded = {}
  for _, ft in ipairs(M.config.exclude_filetypes) do _excluded[ft] = true end

  vim.api.nvim_set_decoration_provider(_NS, { on_win = _on_win, on_end = _on_end })
  _setup_highlights()

  local group = vim.api.nvim_create_augroup(_AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = _setup_highlights,
  })
  -- Not needed until the buffer is shown again.
  vim.api.nvim_create_autocmd("BufHidden", {
    group = group,
    callback = function(ev) _indents[ev.buf] = nil end,
  })
  -- Indent guides alone do not depend on the cursor.
  if M.config.scope then
    vim.api.nvim_create_autocmd(
      { "CursorMoved", "CursorMovedI", "TextChanged", "TextChangedI", "WinEnter", "BufWinEnter" }, {
        group = group,
        callback = function() _update(vim.api.nvim_get_current_win()) end,
      })
    vim.api.nvim_create_autocmd("WinLeave", {
      group = group,
      callback = function() _clear(vim.api.nvim_get_current_win()) end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      callback = function(ev) _scopes[tonumber(ev.match)] = nil end,
    })
  end

  -- At the next redraw: redrawing now, possibly mid-startup, would also drop
  -- pending messages.
  vim.api.nvim__redraw({ valid = false })
end

function M.disable()
  _enabled = false
  _scopes = {}
  _indents = {}
  vim.api.nvim_set_decoration_provider(_NS, {})
  vim.api.nvim_create_augroup(_AUGROUP, { clear = true })
  vim.api.nvim__redraw({ valid = false })
end

function M.toggle()
  if _enabled then M.disable() else M.enable() end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

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

---@param opts keystone.scope.Config?
function M.setup(opts)
  _setup = true
  cfgutil.apply(M.config, _default_config, opts)

  if _enabled then M.disable() end
  if M.config.enabled then
    M.enable()
  end
end

return M
