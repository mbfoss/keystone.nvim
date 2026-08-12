---@class keystone.select
local M = {}

local ui = require("keystone.util.ui")

-- ---------------------------------------------------------------------------
-- A deliberately small picker: the minimal subset of a fuzzy picker needed to
-- implement `vim.ui.select`. A prompt float sitting directly on a list float --
-- one shared frame, helix style -- and -- when
-- the caller passes `preview_item` -- a preview float that simply displays a
-- *buffer* the caller hands back. Nothing else: no sources, no async finders, no
-- flags, no history. Anything richer belongs in a real picker plugin.
--
-- Standalone, like every keystone module: `setup()` replaces `vim.ui.select`
-- with this picker, and nothing happens until the user asks for it. No other
-- keystone module requires this one -- the ones that prompt for a choice call
-- `vim.ui.select`, so they get whichever implementation the user installed.
--
-- Implements the `preview_item` field in `vim.ui.select.Opts` added in neovim 12
-- ---------------------------------------------------------------------------

local _NS_MATCH   = vim.api.nvim_create_namespace("keystone_select_match")
local _NS_CURSOR  = vim.api.nvim_create_namespace("keystone_select_cursor")
local _NS_PREVIEW = vim.api.nvim_create_namespace("keystone_select_preview")

local _HL_MATCH   = "KeystoneSelectMatch"
vim.api.nvim_set_hl(0, _HL_MATCH, { default = true, link = "Special" })

-- nvim_win_set_buf drops parts of 'winhighlight', so it is re-applied on every
-- preview swap; keep it in one place.
local _WINHL      = "NormalFloat:Normal,FloatBorder:Normal,FloatTitle:Title"

-- Leading room in the list for the selection marker.
local _PREFIX     = "  "

-- Columns left between the list and the preview beside it.
local _GAP        = 2

-- Helix-style framing. The rule between the prompt and the list is the list's
-- top border, not the prompt's bottom one: the count rides on it as a title, and
-- a title belongs to the window whose contents it counts -- so keeping it there
-- leaves the focused prompt window untouched as the count changes.
local _BORDER_TOP    = { "╭", "─", "╮", "│", "", "", "", "│" }
local _BORDER_BOTTOM = { "│", { "─", "NonText" }, "│", "│", "╯", "─", "╰", "│" }
local _BORDER_FULL   = "rounded"

-- Rows above the list's first item: the prompt's top border, its single line of
-- text, and the rule below it.
local _PROMPT_ROWS   = 3

--- Sizing for a picker that shows a preview. Fixed fractions of the editor: the
--- preview needs its room whatever the items look like. Height is measured
--- against the rows the picker may use, the command line and statusline aside.
---@class keystone.select.WithPreviewConfig
---@field width_ratio number Fraction of the editor width the picker occupies; the list takes half of it, the preview the other half.
---@field height_ratio number Fraction of the editor height the picker occupies.

--- Sizing for a picker without a preview, where the items decide within bounds.
--- Every ratio is a fraction of the editor -- of the rows it may use, for the
--- heights; the `max_` pair also has to cover the prompt above the list, the
--- `min_` pair applies to the list alone.
---@class keystone.select.WithoutPreviewConfig
---@field min_width_ratio number Width the list keeps however narrow its labels.
---@field max_width_ratio number Width the widest label may grow the list to.
---@field min_height_ratio number Height the list keeps however few the items.
---@field max_height_ratio number Height the picker may grow to.

---@class keystone.select.Config
---@field enabled boolean Install the `vim.ui.select` override.
---@field sort boolean Order filtered items by fuzzy score instead of the caller's order.
---@field with_preview keystone.select.WithPreviewConfig
---@field without_preview keystone.select.WithoutPreviewConfig

---@return keystone.select.Config
local function _default_config()
    return {
        enabled         = true,
        sort            = false,
        with_preview    = {
            width_ratio  = 0.8,
            height_ratio = 0.7,
        },
        without_preview = {
            min_width_ratio  = 0.4,
            max_width_ratio  = 0.8,
            min_height_ratio = 0.2,
            max_height_ratio = 0.7,
        },
    }
end

---@type keystone.select.Config
M.config = _default_config()

---@class keystone.select.Preview
---@field buf integer Buffer to display. May be a live, modified buffer.
---@field pos {[1]:integer,[2]:integer}? 1-based line, 0-based column to reveal.
---@field pos_end {[1]:integer,[2]:integer}? End of the highlighted region.

---@class keystone.select.Opts : vim.ui.select.Opts
---@field preview_item (fun(item:any):keystone.select.Preview?)? keystone extension.

---@class keystone.select.Entry
---@field label string
---@field item any
---@field idx integer 1-based index within the caller's `items`.

---@class keystone.select.Layout
---@field row integer
---@field col integer
---@field list_width integer Width of the prompt and the list alike -- they share one frame.
---@field list_height integer
---@field preview_width integer

---@param v number
---@param min number
---@param max number
---@return number
local function _clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

---@param total integer Editor width or height, in cells.
---@param ratio number
---@param min number Smallest ratio worth honouring.
---@param max number Largest ratio worth honouring.
---@return integer
local function _cells(total, ratio, min, max)
    return math.ceil(total * _clamp(ratio, min, max))
end

--- Whether a statusline is drawn at the bottom of the editor. With
--- `laststatus == 1`, assume no status line
---@return boolean
local function _has_statusline()
    local laststatus = vim.o.laststatus
    return laststatus ~= 0 and laststatus ~=1
end

--- Editor rows the picker may occupy: everything `vim.o.lines` counts, less the
--- command line and the statusline. The floats are placed relative to the
--- editor, whose row 0 is the top of the screen, so those rows come off the
--- bottom and centring within what is left keeps the picker off the command line.
---@return integer
local function _usable_lines()
    local reserved = vim.o.cmdheight + (_has_statusline() and 1 or 0)
    return math.max(1, vim.o.lines - reserved)
end

--- The one cell to hand the picker when centring `span` within `available`
--- would leave an odd remainder. Nothing splits an odd number in two, and the
--- `math.floor` below would drop the spare cell past the bottom right corner;
--- spending it on the picker keeps the gaps either side identical.
---@param span integer
---@param available integer
---@return integer 0 or 1
local function _spare(span, available)
    if span >= available or (available - span) % 2 == 0 then
        return 0
    end
    return 1
end

--- Centre the floats as one block and fill in the rest of the layout.
---@param list_width integer
---@param list_height integer
---@param preview_width integer 0 without a preview.
---@return keystone.select.Layout
local function _centre(list_width, list_height, preview_width)
    local cols, lines = vim.o.columns, _usable_lines()
    local gap = preview_width > 0 and _GAP or 0

    -- Rows consumed: the prompt's top border and text, the list, and the single
    -- bottom border closing the shared frame -- the edge between them is drawn
    -- by neither float.
    local total_height = _PROMPT_ROWS + list_height + 1
    -- Columns consumed: the floats side by side, plus the border either side of
    -- the block -- `nvim_open_win` draws a border on the column it is handed, so
    -- each float reaches one past its width. `_GAP` pays for the two that meet
    -- in the middle, leaving the outer pair to count here.
    local total_width  = list_width + gap + preview_width + 2

    -- Whatever an odd remainder leaves over goes to the picker; see `_spare`.
    local grow_height  = _spare(total_height, lines)
    local grow_width   = _spare(total_width, cols)
    list_height        = list_height + grow_height
    total_height       = total_height + grow_height
    total_width        = total_width + grow_width
    if preview_width > 0 then
        preview_width = preview_width + grow_width
    else
        list_width = list_width + grow_width
    end

    return {
        row           = math.max(0, math.floor((lines - total_height) / 2)),
        col           = math.max(0, math.floor((cols - total_width) / 2)),
        list_width    = list_width,
        list_height   = list_height,
        preview_width = preview_width,
    }
end

--- Geometry for the three floats. With a preview the block is a fixed fraction of
--- the editor whatever the items look like: the preview needs the room even when
--- the list is short, and a fixed block keeps the floats where they are as a query
--- filters the list down.
---
--- Without a preview nothing else shares the row, so there the items decide the
--- size within the configured bounds: the list is as wide as its widest label and
--- as tall as it has items, so a two-item choice reads as a small menu rather than
--- a mostly empty picker. Both are measured once, over the caller's full item list,
--- so filtering still does not resize anything.
---@param has_preview boolean
---@param want_width integer Widest label, in display cells.
---@param want_height integer Number of items.
---@return keystone.select.Layout
local function _compute_layout(has_preview, want_width, want_height)
    local cols, lines = vim.o.columns, _usable_lines()

    if has_preview then
        local cfg = M.config.with_preview
        -- `width_ratio` buys the whole row: the two floats split what the gap
        -- between them leaves, the list taking the smaller half of an odd rest.
        local rest = math.max(2, _cells(cols, cfg.width_ratio, 0.2, 1.0) - _GAP)
        local list_width = math.floor(rest / 2)
        return _centre(
            list_width,
            _clamp(_cells(lines, cfg.height_ratio, 0.3, 0.9) - 4, 1, math.max(1, lines - 4)),
            rest - list_width)
    end

    local cfg = M.config.without_preview

    -- `math.max` / `math.min` against the opposite bound, so the ceiling wins where
    -- the two ratios cross: a floor may not push the picker past its maximum.
    local max_width = _cells(cols, cfg.max_width_ratio, 0.1, 1.0)
    local min_width = math.min(_cells(cols, cfg.min_width_ratio, 0, 1.0), max_width)

    local max_height = _clamp(
        _cells(lines, cfg.max_height_ratio, 0.3, 0.9) - 4, 1, math.max(1, lines - 4))
    local min_height = math.min(_cells(lines, cfg.min_height_ratio, 0, 0.9), max_height)

    return _centre(
        _clamp(want_width + #_PREFIX + 1, math.max(1, min_width), max_width),
        _clamp(want_height, math.max(1, min_height), max_height),
        0)
end

---@class keystone.select.Picker
---@field private _entries keystone.select.Entry[]
---@field private _pool {label:string,i:integer}[] Match input; `i` indexes `_entries`.
---@field private _matches keystone.select.Entry[] Currently displayed subset.
---@field private _positions integer[][]? Matched char positions, per displayed row.
---@field private _preview_item (fun(item:any):keystone.select.Preview?)?
---@field private _on_choice fun(item:any?, idx:integer?)
---@field private _layout keystone.select.Layout
---@field private _want_width integer Widest label, in display cells; fixed for the picker's life.
---@field private _want_height integer Number of items; fixed for the picker's life.
---@field private _title string Prompt border title, re-applied on every relayout.
---@field private _count string? List border title: the cursor position, right aligned.
---@field private _query string
---@field private _closed boolean
---@field private _pbuf integer?
---@field private _lbuf integer?
---@field private _vbuf integer? Placeholder shown when an item has no preview.
---@field private _pwin integer?
---@field private _lwin integer?
---@field private _vwin integer?
---@field private _external_buf integer? Foreign buffer currently in the preview window.
local Picker = {}
Picker.__index = Picker

--- The picker owns the whole screen while it is up, so only one may exist.
---@type keystone.select.Picker?
local _active = nil

---@param entries keystone.select.Entry[]
---@param opts keystone.select.Opts
---@param on_choice fun(item:any?, idx:integer?)
---@return keystone.select.Picker
function Picker.new(entries, opts, on_choice)
    local self = setmetatable({}, Picker)

    self._entries      = entries
    self._matches      = entries
    self._positions    = nil
    self._preview_item = opts.preview_item
    self._on_choice    = on_choice
    self._query        = ""
    self._closed       = false

    self._pool         = {}
    self._want_width   = 0
    self._want_height  = #entries
    for i, entry in ipairs(entries) do
        self._pool[i] = { label = entry.label, i = i }
        self._want_width = math.max(self._want_width, vim.fn.strdisplaywidth(entry.label))
    end

    self._layout = _compute_layout(self._preview_item ~= nil, self._want_width, self._want_height)
    self:_open(opts.prompt and opts.prompt:gsub("%s*:%s*$", "") or "Select")
    self:_render()

    return self
end

---@param title string
---@return nil
function Picker:_open(title)
    local base  = { relative = "editor", style = "minimal" }
    local L     = self._layout
    self._title = " " .. title .. " "

    self._pbuf = ui.create_scratch_buffer(false, { modifiable = true })
    self._lbuf = ui.create_scratch_buffer(false, { modifiable = false })

    local augroup
    self._pwin, augroup = ui.create_window(self._pbuf, true,
        vim.tbl_extend("force", base, self:_prompt_config()),
        function() self:_finish(nil) end)
    vim.wo[self._pwin].winhighlight = _WINHL
    vim.wo[self._pwin].wrap = false

    self._lwin = ui.create_window(self._lbuf, false,
        vim.tbl_extend("force", base, self:_list_config()),
        function() self:_finish(nil) end)
    vim.wo[self._lwin].winhighlight = _WINHL
    vim.wo[self._lwin].wrap = false

    if self._preview_item then
        -- 'hide', not the scratch default 'wipe': the placeholder goes hidden
        -- every time a real preview buffer takes over the window, and wiping it
        -- there would leave nothing to fall back to.
        self._vbuf = ui.create_scratch_buffer(false, { modifiable = false, bufhidden = "hide" })
        -- Its top border lands on `row`, the same one the prompt's does, and its
        -- height is the rows between the two -- so the preview closes level with
        -- the bottom of the frame beside it.
        self._vwin = ui.create_window(self._vbuf, false, vim.tbl_extend("force", base, {
            row    = L.row,
            col    = L.col + L.list_width + 2,
            width  = L.preview_width,
            height = L.list_height + _PROMPT_ROWS - 1,
            border = _BORDER_FULL,
        }), function() self:_finish(nil) end)
        vim.wo[self._vwin].winhighlight = _WINHL
        vim.wo[self._vwin].wrap = false
    end

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer   = self._pbuf,
        callback = function() self:_apply_prompt() end,
    })

    -- Focus landing anywhere outside the picker's own floats means the user has
    -- moved on; the picker is modal, so it goes away with them.
    vim.api.nvim_create_autocmd("WinEnter", {
        group    = augroup,
        callback = function()
            local win = vim.api.nvim_get_current_win()
            if win ~= self._pwin and win ~= self._lwin and win ~= self._vwin then
                vim.schedule(function() self:_finish(nil) end)
            end
        end,
    })
    vim.api.nvim_create_autocmd("VimResized", {
        group    = augroup,
        callback = function() vim.schedule(function() self:_relayout() end) end,
    })

    self:_map({ "i", "n" }, "<CR>", function() self:_confirm() end)
    self:_map("n", "<Esc>", function() self:_finish(nil) end)
    self:_map("i", "<C-c>", function() self:_finish(nil) end)
    self:_map({ "i", "n" }, "<C-n>", function() self:_move(self:_row() + 1, false) end)
    self:_map({ "i", "n" }, "<C-p>", function() self:_move(self:_row() - 1, false) end)
    self:_map({ "i", "n" }, "<Down>", function() self:_move(self:_row() + 1, false) end)
    self:_map({ "i", "n" }, "<Up>", function() self:_move(self:_row() - 1, false) end)
    self:_map({ "i", "n" }, "<C-d>", function()
        self:_move(self:_row() + math.floor(self._layout.list_height / 2), true)
    end)
    self:_map({ "i", "n" }, "<C-u>", function()
        self:_move(self:_row() - math.floor(self._layout.list_height / 2), true)
    end)

    -- Reachable by clicking into the list; keep the two decisive keys working there.
    local list_opts = { buffer = self._lbuf, nowait = true, silent = true }
    vim.keymap.set("n", "<CR>", function() self:_confirm() end, list_opts)
    vim.keymap.set("n", "<Esc>", function() self:_finish(nil) end, list_opts)

    -- Deferred: `M.select` is usually called from inside another callback, where
    -- an immediate `startinsert` would be undone as that callback unwinds.
    vim.schedule(function()
        if not self._closed and vim.api.nvim_get_current_win() == self._pwin then
            vim.cmd("startinsert!")
        end
    end)
end

--- Window config for the prompt float. `nvim_win_set_config` resets what it is
--- not handed, so the border and title come along on every call.
---@return vim.api.keyset.win_config
function Picker:_prompt_config()
    local L = self._layout
    return {
        relative  = "editor",
        row       = L.row,
        col       = L.col,
        width     = L.list_width,
        height    = 1,
        border    = _BORDER_TOP,
        title     = self._title,
        title_pos = "center",
    }
end

--- Window config for the list float. Its top border is the rule under the
--- prompt -- hence the row one above the list's own first line -- and carries
--- the count as its title.
---@return vim.api.keyset.win_config
function Picker:_list_config()
    local L = self._layout
    return {
        relative  = "editor",
        row       = L.row + _PROMPT_ROWS - 1,
        col       = L.col,
        width     = L.list_width,
        height    = L.list_height,
        border    = _BORDER_BOTTOM,
        title     = self:_title_count(),
        title_pos = "right",
    }
end

--- The title chunks for the current count; `""` when there is nothing to show,
--- since `nvim_win_set_config` ignores a key it is handed as nil and would leave
--- a stale count on the border.
---@return [string, string][]|string
function Picker:_title_count()
    return self._count and { { " " .. self._count, "NonText" } } or ""
end

---@param mode string|string[]
---@param lhs string
---@param rhs fun()
---@return nil
function Picker:_map(mode, lhs, rhs)
    vim.keymap.set(mode, lhs, rhs, { buffer = self._pbuf, nowait = true, silent = true })
end

---@return nil
function Picker:_relayout()
    if self._closed then return end

    local L = _compute_layout(self._preview_item ~= nil, self._want_width, self._want_height)
    self._layout = L

    vim.api.nvim_win_set_config(self._pwin, self:_prompt_config())
    vim.api.nvim_win_set_config(self._lwin, self:_list_config())
    if self._vwin then
        vim.api.nvim_win_set_config(self._vwin, {
            relative = "editor", row = L.row, col = L.col + L.list_width + 2,
            width = L.preview_width, height = L.list_height + _PROMPT_ROWS - 1,
            border = _BORDER_FULL,
        })
    end
end

---@return nil
function Picker:_apply_prompt()
    if self._closed then return end

    -- A paste can drop several lines (and control characters) into the prompt;
    -- flatten it back to the single line the rest of the picker assumes.
    local lines = vim.api.nvim_buf_get_lines(self._pbuf, 0, -1, false)
    local raw   = table.concat(lines, "")
    local text  = raw:gsub("%c", "")
    if #lines > 1 or text ~= raw then
        local col = vim.api.nvim_win_get_cursor(self._pwin)[2]
        vim.api.nvim_buf_set_lines(self._pbuf, 0, -1, false, { text })
        vim.api.nvim_win_set_cursor(self._pwin, { 1, math.min(col, #text) })
    end

    if text == self._query then return end
    self._query = text
    self:_filter()
    self:_render()
end

---@return nil
function Picker:_filter()
    if self._query == "" then
        self._matches = self._entries -- caller's order, unscored
        self._positions = nil
        return
    end

    -- Matched over a list of `{label, i}` dictionaries rather than the entries
    -- themselves: matchfuzzypos round-trips its input through Vimscript, which
    -- would copy (and so break the identity of) the caller's items.
    local result = vim.fn.matchfuzzypos(self._pool, self._query, { key = "label" })
    local hits   = result[1]

    -- matchfuzzypos hands its hits back best-score-first. Unless sorting is
    -- asked for, put them back in the caller's order: a `vim.ui.select` list is
    -- usually already ordered meaningfully, and rows jumping around as the query
    -- grows makes the list hard to follow.
    local order = {}
    for row = 1, #hits do
        order[row] = row
    end
    if not M.config.sort then
        table.sort(order, function(a, b) return hits[a].i < hits[b].i end)
    end

    self._matches   = {}
    self._positions = {}
    for row, hit_row in ipairs(order) do
        self._matches[row]   = self._entries[hits[hit_row].i]
        self._positions[row] = result[2][hit_row]
    end
end

---@return nil
function Picker:_render()
    local lines = {}
    for _, entry in ipairs(self._matches) do
        table.insert(lines, _PREFIX .. entry.label)
    end

    vim.bo[self._lbuf].modifiable = true
    vim.api.nvim_buf_set_lines(self._lbuf, 0, -1, false, lines)
    vim.bo[self._lbuf].modifiable = false

    vim.api.nvim_buf_clear_namespace(self._lbuf, _NS_MATCH, 0, -1)
    for row, positions in ipairs(self._positions or {}) do
        local label = self._matches[row] and self._matches[row].label
        if label then
            for _, pos in ipairs(positions) do
                -- matchfuzzypos reports 0-based *character* positions.
                local start_col = vim.fn.byteidx(label, pos)
                if start_col >= 0 then
                    local end_col = vim.fn.byteidx(label, pos + 1)
                    if end_col < 0 then end_col = #label end
                    vim.api.nvim_buf_set_extmark(self._lbuf, _NS_MATCH, row - 1, #_PREFIX + start_col, {
                        end_col  = #_PREFIX + end_col,
                        hl_group = _HL_MATCH,
                    })
                end
            end
        end
    end

    vim.wo[self._lwin].cursorline = #lines > 0
    self:_move(1, true)
end

---@return nil
function Picker:_render_cursor()
    vim.api.nvim_buf_clear_namespace(self._lbuf, _NS_CURSOR, 0, -1)
    if #self._matches == 0 then
        self:_set_count(nil)
        return
    end

    local row = self:_row()
    vim.api.nvim_buf_set_extmark(self._lbuf, _NS_CURSOR, row - 1, 0, {
        virt_text     = { { "❯ ", "Special" } },
        virt_text_pos = "overlay",
        priority      = 100,
    })
    self:_set_count(string.format("%d/%d", row, #self._matches))
end

--- Show `count` on the rule above the list, right aligned. The list window is
--- never the focused one, so re-configuring it costs no cursor flicker.
---@param count string? Text, or nil to clear.
---@return nil
function Picker:_set_count(count)
    if count == self._count then return end
    self._count = count
    if self._lwin and vim.api.nvim_win_is_valid(self._lwin) then
        vim.api.nvim_win_set_config(self._lwin, self:_list_config())
    end
end

---@return integer row 1-based row of the highlighted item.
function Picker:_row()
    return vim.api.nvim_win_get_cursor(self._lwin)[1]
end

---@return keystone.select.Entry?
function Picker:_current()
    return self._matches[self:_row()]
end

--- Move the highlight to `row`, wrapping around the ends unless `clamp`.
---@param row integer
---@param clamp boolean
---@return nil
function Picker:_move(row, clamp)
    local total = #self._matches
    if total == 0 then
        self:_render_cursor()
        self:_update_preview()
        return
    end

    if clamp then
        row = _clamp(row, 1, total)
    elseif row > total then
        row = 1
    elseif row < 1 then
        row = total
    end

    vim.api.nvim_win_set_cursor(self._lwin, { row, 0 })
    self:_render_cursor()
    self:_update_preview()
end

---@return nil
function Picker:_update_preview()
    local vwin, vbuf, preview_item = self._vwin, self._vbuf, self._preview_item
    if not (vwin and vbuf and preview_item) then return end

    local entry   = self:_current()
    local preview = entry and preview_item(entry.item) or nil

    self:_release_preview()

    if preview and preview.buf and vim.api.nvim_buf_is_valid(preview.buf) then
        self._external_buf = preview.buf
        vim.api.nvim_win_set_buf(vwin, preview.buf)
        vim.wo[vwin].winhighlight = _WINHL
        self:_reveal(vwin, preview.buf, preview.pos, preview.pos_end)
        return
    end

    vim.bo[vbuf].modifiable = true
    vim.api.nvim_buf_set_lines(vbuf, 0, -1, false, entry and { "", "  No preview" } or {})
    vim.bo[vbuf].modifiable = false
end

--- Put the preview window back on its placeholder buffer and take keystone's
--- extmarks off the foreign buffer -- it belongs to the user, not to us.
---@return nil
function Picker:_release_preview()
    local buf = self._external_buf
    self._external_buf = nil
    if not buf then return end
    if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, _NS_PREVIEW, 0, -1)
    end
    if self._vwin and vim.api.nvim_win_is_valid(self._vwin) and vim.api.nvim_win_get_buf(self._vwin) == buf then
        vim.api.nvim_win_set_buf(self._vwin, self._vbuf)
        vim.wo[self._vwin].winhighlight = _WINHL
    end
end

---@param win integer
---@param buf integer
---@param pos {[1]:integer,[2]:integer}?
---@param pos_end {[1]:integer,[2]:integer}?
---@return nil
function Picker:_reveal(win, buf, pos, pos_end)
    if not pos then
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        return
    end

    local last = vim.api.nvim_buf_line_count(buf)
    local lnum = _clamp(pos[1], 1, last)
    local col  = math.max(0, pos[2] or 0)
    vim.api.nvim_win_call(win, function()
        -- The stored column can be past the end of a line that has since been
        -- edited; the line itself is what matters, so fall back to its start.
        if not pcall(vim.api.nvim_win_set_cursor, win, { lnum, col }) then
            vim.api.nvim_win_set_cursor(win, { lnum, 0 })
        end
        vim.cmd("normal! zz")
    end)

    vim.api.nvim_buf_set_extmark(buf, _NS_PREVIEW, lnum - 1, pos_end and col or 0, {
        end_row  = pos_end and (_clamp(pos_end[1], lnum, last) - 1) or lnum,
        end_col  = pos_end and pos_end[2] or nil,
        hl_group = "Visual",
        hl_eol   = true,
        hl_mode  = "blend",
    })
end

---@return nil
function Picker:_confirm()
    self:_finish(self:_current())
end

--- Tear the picker down and report `entry` (or an abort, when nil). Every exit
--- path -- confirm, cancel, a window being closed from outside -- lands here.
---@param entry keystone.select.Entry?
---@return nil
function Picker:_finish(entry)
    if self._closed then return end
    self._closed = true
    if _active == self then _active = nil end

    self:_release_preview()

    -- Leaving insert mode steps the cursor one column left, and `:stopinsert`
    -- only takes effect once this callback returns -- so the floats have to
    -- outlive it, or that step lands in the window the focus falls back to.
    vim.cmd("stopinsert")

    vim.schedule(function()
        for _, win in ipairs({ self._pwin, self._lwin, self._vwin }) do
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
            end
        end
        for _, buf in ipairs({ self._pbuf, self._lbuf, self._vbuf }) do
            if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end

        if entry then
            self._on_choice(entry.item, entry.idx)
        else
            self._on_choice(nil, nil)
        end
    end)
end

--- A `vim.ui.select` implementation: prompts for one of `items` in a floating
--- picker, with fuzzy filtering over the formatted labels.
---@generic T
---@param items T[] Arbitrary items.
---@param opts keystone.select.Opts
---@param on_choice fun(item: T|nil, idx: integer|nil)
---               Called once the user made a choice.
---               `idx` is the 1-based index of `item` within `items`.
---               `nil` if the user aborted the dialog.
---@return nil
function M.select(items, opts, on_choice)
    vim.validate("items", items, "table")
    vim.validate("on_choice", on_choice, "function")
    opts = opts or {}

    local format_item = opts.format_item or tostring

    ---@type keystone.select.Entry[]
    local entries = {}
    for i, item in ipairs(items) do
        entries[i] = {
            label = tostring(format_item(item)):gsub("\n", " "),
            item  = item,
            idx   = i,
        }
    end

    if _active then _active:_finish(nil) end
    _active = Picker.new(entries, opts, on_choice)
end

--- Install this picker as `vim.ui.select`. Everything that prompts for a choice
--- -- keystone's own commands, the LSP's code actions, other plugins -- goes
--- through it from here on.
---@param opts keystone.select.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _default_config(), opts or {})
    if not M.config.enabled then return end

    vim.ui.select = M.select
end

return M
