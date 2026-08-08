---@class keystone.select
local M = {}

local ui = require("keystone.util.ui")

-- ---------------------------------------------------------------------------
-- A deliberately small picker: the minimal subset of a fuzzy picker needed to
-- implement `vim.ui.select`. A prompt float, a filtered list float and -- when
-- the caller passes `preview_item` -- a preview float that simply displays a
-- *buffer* the caller hands back. Nothing else: no sources, no async finders, no
-- flags, no history. Anything richer belongs in a real picker plugin.
--
-- Standalone, like every keystone module: `setup()` replaces `vim.ui.select`
-- with this picker, and nothing happens until the user asks for it. No other
-- keystone module requires this one -- the ones that prompt for a choice call
-- `vim.ui.select`, so they get whichever implementation the user installed.
--
-- `preview_item` is this module's one extension over `vim.ui.select.Opts`; other
-- implementations ignore an unknown option, so callers can pass it freely.
-- Because the preview is a real buffer rather than a copy of its lines, live
-- (unsaved) contents, syntax and extmarks show up as they are.
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

---@class keystone.select.Config
---@field enabled boolean Install the `vim.ui.select` override.
---@field width_ratio number Fraction of the editor width the list occupies; a minimum without a preview.
---@field height_ratio number Fraction of the editor height the picker occupies.
---@field sort boolean Order filtered items by fuzzy score instead of the caller's order.

---@return keystone.select.Config
local function _default_config()
    return {
        enabled      = true,
        width_ratio  = 0.4,
        height_ratio = 0.7,
        sort         = false,
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
---@field width integer Prompt width -- spans the list, the gap and the preview.
---@field list_width integer
---@field list_height integer
---@field preview_width integer

---@param v number
---@param min number
---@param max number
---@return number
local function _clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

--- Geometry for the three floats, centred as one block. The size is a fraction of
--- the editor whatever the items look like: a short or narrow list leaves empty
--- space rather than shrinking the picker, so the floats keep the same size and
--- position as a query filters the list down.
---
--- The one thing the items still decide is how far past `width_ratio` a
--- preview-less list may grow: there the ratio is a floor rather than the width,
--- since nothing shares the row and truncating labels would cost more than the
--- extra columns.
---@param has_preview boolean
---@param want_width integer Widest label, in display cells.
---@return keystone.select.Layout
local function _compute_layout(has_preview, want_width)
    local cols, lines = vim.o.columns, vim.o.lines
    local gap = has_preview and 2 or 0

    local list_height = _clamp(
        math.ceil(lines * _clamp(M.config.height_ratio, 0.3, 0.9)) - 3, 1, math.max(1, lines - 6))
    local list_width = math.ceil(cols * _clamp(M.config.width_ratio, 0.1, 0.8))

    local preview_width = 0
    if has_preview then
        preview_width = _clamp(math.min(list_width * 2, cols) - list_width - 1, 1, cols)
    else
        list_width = _clamp(want_width + #_PREFIX + 1, list_width, math.ceil(cols * 0.8))
    end

    -- Rows consumed: prompt (border + text + border) then the list's own border.
    local total_height = 3 + list_height + 2
    return {
        row           = math.max(0, math.floor((lines - total_height) / 2)),
        col           = math.max(0, math.floor((cols - (list_width + gap + preview_width)) / 2)),
        width         = list_width + gap + preview_width,
        list_width    = list_width,
        list_height   = list_height,
        preview_width = preview_width,
    }
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
    for i, entry in ipairs(entries) do
        self._pool[i] = { label = entry.label, i = i }
        self._want_width = math.max(self._want_width, vim.fn.strdisplaywidth(entry.label))
    end

    self._layout = _compute_layout(self._preview_item ~= nil, self._want_width)
    self:_open(opts.prompt and opts.prompt:gsub("%s*:%s*$", "") or "Select")
    self:_render()

    return self
end

---@param title string
---@return nil
function Picker:_open(title)
    local base = { relative = "editor", style = "minimal", border = "rounded" }
    local L    = self._layout

    self._pbuf = ui.create_scratch_buffer(false, { modifiable = true })
    self._lbuf = ui.create_scratch_buffer(false, { modifiable = false })

    local augroup
    self._pwin, augroup = ui.create_window(self._pbuf, true, vim.tbl_extend("force", base, {
        row       = L.row,
        col       = L.col,
        width     = L.width,
        height    = 1,
        title     = " " .. title .. " ",
        title_pos = "center",
    }), function() self:_finish(nil) end)
    vim.wo[self._pwin].winhighlight = _WINHL
    vim.wo[self._pwin].wrap = false

    self._lwin = ui.create_window(self._lbuf, false, vim.tbl_extend("force", base, {
        row    = L.row + 3,
        col    = L.col,
        width  = L.list_width,
        height = L.list_height,
    }), function() self:_finish(nil) end)
    vim.wo[self._lwin].winhighlight = _WINHL
    vim.wo[self._lwin].wrap = false

    if self._preview_item then
        -- 'hide', not the scratch default 'wipe': the placeholder goes hidden
        -- every time a real preview buffer takes over the window, and wiping it
        -- there would leave nothing to fall back to.
        self._vbuf = ui.create_scratch_buffer(false, { modifiable = false, bufhidden = "hide" })
        self._vwin = ui.create_window(self._vbuf, false, vim.tbl_extend("force", base, {
            row    = L.row + 3,
            col    = L.col + L.list_width + 2,
            width  = L.preview_width,
            height = L.list_height,
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

    local L = _compute_layout(self._preview_item ~= nil, self._want_width)
    self._layout = L

    vim.api.nvim_win_set_config(self._pwin, {
        relative = "editor", row = L.row, col = L.col, width = L.width, height = 1,
    })
    vim.api.nvim_win_set_config(self._lwin, {
        relative = "editor", row = L.row + 3, col = L.col,
        width = L.list_width, height = L.list_height,
    })
    if self._vwin then
        vim.api.nvim_win_set_config(self._vwin, {
            relative = "editor", row = L.row + 3, col = L.col + L.list_width + 2,
            width = L.preview_width, height = L.list_height,
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
    vim.api.nvim_buf_clear_namespace(self._pbuf, _NS_CURSOR, 0, -1)
    if #self._matches == 0 then return end

    local row = self:_row()
    vim.api.nvim_buf_set_extmark(self._lbuf, _NS_CURSOR, row - 1, 0, {
        virt_text     = { { "❯ ", "Special" } },
        virt_text_pos = "overlay",
        priority      = 100,
    })
    vim.api.nvim_buf_set_extmark(self._pbuf, _NS_CURSOR, 0, 0, {
        virt_text     = { { string.format("%d/%d", row, #self._matches), "NonText" } },
        virt_text_pos = "eol_right_align",
        hl_mode       = "blend",
        priority      = 50,
    })
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
