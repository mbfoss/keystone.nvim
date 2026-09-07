---@class keystone.select
local M = {}

local ui = require("keystone.util.ui")
local cfgutil = require("keystone.util.config")

-- ---------------------------------------------------------------------------
-- A deliberately small picker: the minimal subset of a fuzzy picker needed to
-- implement `vim.ui.select`. A prompt float sitting on a list float -- one
-- shared frame, the rule between them drawn by the list's winbar -- as a bar
-- across the bottom of the editor. A caller that passes `preview_item` gets a
-- preview float on the right half of that frame, opened with `<C-t>`; `<C-e>`
-- fills the screen with the frame. Nothing else: no sources, no async finders,
-- no flags, no history.
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
local _NS_PROMPT  = vim.api.nvim_create_namespace("keystone_select_prompt")
local _NS_PREVIEW = vim.api.nvim_create_namespace("keystone_select_preview")

local _HL_MATCH   = "KeystoneSelectMatch"
vim.api.nvim_set_hl(0, _HL_MATCH, { default = true, link = "Special" })

-- The rule's own group, so a `NonText` carrying a background does not paint
-- the winbar row in it.
local _HL_RULE    = "KeystoneSelectRule"

-- nvim_win_set_buf drops parts of 'winhighlight', so it is re-applied on every
-- preview swap; keep it in one place.
local _WINHL      = "NormalFloat:Normal,FloatBorder:Normal,FloatTitle:Title," ..
    "WinBar:Normal,WinBarNC:Normal"

-- Leading room in the list for the selection marker.
local _PREFIX     = "  "

-- Fills the list's winbar, so it reads as the rule between prompt and items.
local _RULE       = "─"

-- Rows and columns the outermost border eats.
local _BORDER_SPAN   = 2

-- Helix-style framing. The rule dividing the two floats is the list's winbar,
-- so the list has no top border and its window is one row taller than its items.
local _BORDER_TOP    = { "╭", "─", "╮", "│", "", "", "", "│" }
local _BORDER_BOTTOM = { "", "", "", "│", "╯", "─", "╰", "│" }
local _BORDER_FULL   = "rounded"

-- Rows the prompt float covers: its top border and its single line of text.
local _PROMPT_ROWS   = 2

---@param v number
---@param min number
---@param max number
---@return number
local function _clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

---@return nil
local function _set_rule_hl()
    local src = vim.api.nvim_get_hl(0, { name = "NonText", link = false })
    vim.api.nvim_set_hl(0, _HL_RULE, {
        fg      = src.fg,
        ctermfg = src.ctermfg,
        bg      = "NONE",
        ctermbg = "NONE",
    })
end

_set_rule_hl()

-- `:colorscheme` clears the derived group along with the one it came from.
vim.api.nvim_create_autocmd("ColorScheme", {
    group    = vim.api.nvim_create_augroup("keystone_select_rule_hl", { clear = true }),
    callback = _set_rule_hl,
})

---@class keystone.select.Config
---@field enabled boolean Install the `vim.ui.select` override.
---@field sort boolean Order filtered items by fuzzy score instead of the caller's order.
---@field height_ratio number Share of the usable rows the prompt/list bar spans.
---@field preview_ratio number Share of the frame's width the preview takes.

---@type keystone.select.Config
local _default_config = {
    enabled       = true,
    sort          = false,
    height_ratio  = 0.25,
    preview_ratio = 0.5,
}

---@type keystone.select.Config
M.config = vim.deepcopy(_default_config)

---@class keystone.select.Preview
---@field buf integer Buffer to display. May be a live, modified buffer.
---@field pos {[1]:integer,[2]:integer}? 1-based line, 0-based column to reveal.
---@field pos_end {[1]:integer,[2]:integer}? End of the highlighted region.

--- Options, as `vim.ui.select` takes them plus `preview_item`.
---@class keystone.select.Opts
---@field prompt? string
---@field format_item? fun(item:any):string
---@field kind? string
---@field preview_item? (fun(item:any):keystone.select.Preview?) keystone extension.

---@class keystone.select.Entry
---@field label string
---@field item any
---@field idx integer 1-based index within the caller's `items`.
---@field positions integer[]? Matched character positions, from `matchfuzzypos`.

---@class keystone.select.Layout
---@field prompt_row integer
---@field prompt_col integer
---@field prompt_width integer
---@field prompt_height integer
---@field prompt_border string|table Border the prompt draws; the list completes the frame.
---@field list_row integer
---@field list_col integer
---@field list_width integer
---@field list_height integer
---@field list_border string|table Border the list draws; it has no top edge.
---@field preview_row integer
---@field preview_col integer
---@field preview_width integer
---@field preview_height integer
---@field preview_border string|table Border the preview draws.

--- Whether a statusline is drawn at the bottom of the editor. With
--- `laststatus == 1`, assume no status line.
---@return boolean
local function _has_statusline()
    local laststatus = vim.o.laststatus
    return laststatus ~= 0 and laststatus ~= 1
end

--- Editor rows the picker may occupy: everything `vim.o.lines` counts, less the
--- command line and the statusline.
---@return integer
local function _usable_lines()
    local reserved = vim.o.cmdheight + (_has_statusline() and 1 or 0)
    return math.max(1, vim.o.lines - reserved)
end

--- Height of the list inside a frame of `interior` rows. The prompt takes one
--- row and the rule another; the rest is the list.
---@param interior integer
---@return integer
local function _list_height(interior)
    return math.max(1, interior - 2)
end

--- The frame's top row, width and interior height. `expanded` fills the usable
--- editor; otherwise the frame is a bar across the bottom, `height_ratio` of the
--- usable rows tall, the border ring excluded.
---@param height_ratio number
---@param expanded boolean
---@return integer row
---@return integer width
---@return integer interior
local function _frame(height_ratio, expanded)
    -- A content width of `columns - 4` plus the two border columns spans all but
    -- one cell at either edge of the editor.
    local width = math.max(1, vim.o.columns - 4)

    if expanded then
        return 0, width, math.max(3, _usable_lines() - _BORDER_SPAN)
    end

    local lines    = _usable_lines()
    local interior = math.ceil(lines * _clamp(height_ratio or 0.25, 0.1, 0.9))
    interior = math.min(math.max(3, interior), math.max(3, lines - _BORDER_SPAN))
    -- The bar's bottom border is the last usable row: nothing between it and the
    -- command line.
    return math.max(0, lines - interior - _BORDER_SPAN), width, interior
end

--- Prompt and list in the frame, with the preview -- when shown -- on its right
--- half. The preview runs the full height of the frame, so the split looks the
--- same however tall the frame is.
---@param height_ratio number
---@param preview_ratio number
---@param expanded boolean
---@param preview boolean
---@return keystone.select.Layout
local function _build_layout(height_ratio, preview_ratio, expanded, preview)
    local row, width, interior = _frame(height_ratio, expanded)
    local list_height = _list_height(interior)

    -- Each box keeps its own border ring, and they touch: sharing a column
    -- would put both boxes' corners on the same cell.
    local list_width, preview_width = width, 0
    if preview then
        local ratio = _clamp(preview_ratio or 0.5, 0.1, 0.9)
        preview_width = math.max(1, math.floor((width - 2) * ratio))
        list_width    = math.max(1, width - preview_width - 2)
    end

    local col = 1

    return {
        prompt_row    = row,
        prompt_col    = col,
        prompt_width  = list_width,
        prompt_height = 1,
        prompt_border = _BORDER_TOP,

        list_row    = row + _PROMPT_ROWS,
        list_col    = col,
        list_width  = list_width,
        list_height = list_height,
        list_border = _BORDER_BOTTOM,

        -- Top border level with the prompt's, bottom border with the list's.
        preview_row    = row,
        preview_col    = col + list_width + 2,
        preview_width  = preview_width,
        preview_height = preview and list_height + 2 or 0,
        preview_border = _BORDER_FULL,
    }
end

--- Split a label into display chunks, merging runs of matched characters.
---@param label string
---@param positions integer[]?
---@return {[1]:string,[2]:string?}[]?
local function _chunks(label, positions)
    if not positions or #positions == 0 then return nil end

    local chunks = {} ---@type {[1]:string,[2]:string?}[]
    local last   = 0
    local i      = 1

    while i <= #positions do
        local j = i
        while j < #positions and positions[j + 1] == positions[j] + 1 do
            j = j + 1
        end

        local first = vim.fn.byteidx(label, positions[i])
        local last_byte = vim.fn.byteidx(label, positions[j] + 1)
        if last_byte < 0 then last_byte = #label end

        if first >= 0 then
            if first > last then chunks[#chunks + 1] = { label:sub(last + 1, first) } end
            if last_byte > first then
                chunks[#chunks + 1] = { label:sub(first + 1, last_byte), _HL_MATCH }
            end
            last = last_byte
        end

        i = j + 1
    end

    if last < #label then chunks[#chunks + 1] = { label:sub(last + 1) } end
    return chunks
end

--- Place the preview cursor on `pos` and scroll the line into view.
---@param win integer
---@param lnum integer
---@param col integer?
---@return nil
local function _place_preview_cursor(win, lnum, col)
    vim.api.nvim_win_call(win, function()
        if not col or col < 0 then col = 0 end
        if not pcall(vim.api.nvim_win_set_cursor, win, { lnum, col }) then
            pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
        end
        vim.cmd("normal! zz")
    end)
end

--- Reveal and highlight a region of the preview buffer.
---@param win integer
---@param buf integer
---@param pos {[1]:integer,[2]:integer}?
---@param pos_end {[1]:integer,[2]:integer}?
---@return nil
local function _apply_preview_pos(win, buf, pos, pos_end)
    vim.api.nvim_buf_clear_namespace(buf, _NS_PREVIEW, 0, -1)
    if not pos then
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        return
    end

    local last = vim.api.nvim_buf_line_count(buf)
    local lnum = _clamp(pos[1], 1, last)
    _place_preview_cursor(win, lnum, pos[2])

    -- Without an end position the whole line is highlighted.
    local start_col = 0
    local end_row   = lnum
    local end_col   = nil ---@type integer?
    if pos_end then
        start_col = pos[2] or 0
        end_row   = _clamp(pos_end[1], lnum, last + 1) - 1
        end_col   = pos_end[2]
    end

    vim.api.nvim_buf_set_extmark(buf, _NS_PREVIEW, lnum - 1, start_col, {
        end_row  = end_row,
        end_col  = end_col,
        hl_group = "Visual",
        hl_eol   = true,
        hl_mode  = "blend",
    })
end

---@class keystone.select.Picker
---@field _entries keystone.select.Entry[]
---@field _pool {label:string,i:integer}[] Match input; `i` indexes `_entries`.
---@field _items keystone.select.Entry[] Currently displayed subset.
---@field _preview_item (fun(item:any):keystone.select.Preview?)?
---@field _on_choice fun(item:any?, idx:integer?)
---@field _layout keystone.select.Layout
---@field _title string Prompt border title.
---@field _query string
---@field _expanded boolean Frame fills the editor rather than sitting on the bar.
---@field _closed boolean
---@field _pbuf integer?
---@field _lbuf integer?
---@field _vbuf integer? Placeholder shown when an item has no preview.
---@field _pwin integer?
---@field _lwin integer?
---@field _vwin integer?
---@field _external_buf integer? Foreign buffer currently in the preview window.
---@field _pwin_augroup integer?
---@field _vwin_augroup integer?
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
    ---@type keystone.select.Picker
    local self = setmetatable({}, Picker)

    self._entries      = entries
    self._items        = entries
    self._preview_item = opts.preview_item
    self._on_choice    = on_choice
    self._query        = ""
    self._expanded     = false
    self._closed       = false
    self._title        = " " .. (opts.prompt and opts.prompt:gsub("%s*:%s*$", "") or "Select") .. " "

    self._pool         = {}
    for i, entry in ipairs(entries) do
        self._pool[i] = { label = entry.label, i = i }
    end

    self._layout = _build_layout(M.config.height_ratio, M.config.preview_ratio, self._expanded, false)
    self:_create_windows()
    self:_setup_input()

    vim.api.nvim_set_current_win(self._pwin)
    self:_render_matches()

    -- Deferred: `M.select` is usually called from inside another callback, where
    -- an immediate `startinsert` would be undone as that callback unwinds.
    vim.schedule(function()
        if not self._closed and vim.api.nvim_get_current_win() == self._pwin then
            vim.cmd("startinsert!")
        end
    end)

    return self
end

--- Build the float configs off `self._layout`.
---@return table<string, table>
function Picker:_float_cfgs()
    local l = self._layout

    ---@param cfg table Placement and border, read off the layout.
    ---@return table
    local function float_cfg(cfg)
        return vim.tbl_extend("force", { relative = "editor", style = "minimal" }, cfg)
    end

    return {
        prompt = float_cfg {
            row       = l.prompt_row,
            col       = l.prompt_col,
            width     = l.prompt_width,
            height    = l.prompt_height,
            border    = l.prompt_border,
            title     = self._title,
            title_pos = "center",
        },
        -- The list has no top border: its first row is the winbar drawing the
        -- rule under the prompt, which the extra row of height pays for.
        list = float_cfg {
            row    = l.list_row,
            col    = l.list_col,
            width  = l.list_width,
            height = l.list_height + 1,
            border = l.list_border,
        },
        preview = float_cfg {
            row    = l.preview_row,
            col    = l.preview_col,
            width  = l.preview_width,
            height = l.preview_height,
            border = l.preview_border,
        },
    }
end

--- Draw the selection marker in front of the query as inline virtual text: it
--- takes screen cells, not buffer ones, so `_apply_prompt` still reads the query
--- alone and the cursor sits after the marker.
---@return nil
function Picker:_render_prompt_marker()
    vim.api.nvim_buf_clear_namespace(self._pbuf, _NS_PROMPT, 0, -1)
    -- Left-gravity: typing at the start of the line must not push the marker
    -- along with the query.
    vim.api.nvim_buf_set_extmark(self._pbuf, _NS_PROMPT, 0, 0, {
        virt_text     = { { "❯ ", "NonText" } },
        virt_text_pos = "inline",
        right_gravity = false,
    })
end

--- Creates the prompt and list buffers and floats. Called once, at picker open.
---@return nil
function Picker:_create_windows()
    local cfgs = self:_float_cfgs()

    self._pbuf = ui.create_scratch_buffer(false, { modifiable = true }, function()
        self._pbuf = nil
        self:_close_soon()
    end)
    self:_render_prompt_marker()
    self._pwin, self._pwin_augroup = ui.create_window(self._pbuf, true, cfgs.prompt, function()
        self._pwin = nil
        self:_close_soon()
    end)
    local pwo = vim.wo[self._pwin][0]
    pwo.winhighlight = _WINHL
    pwo.wrap = false

    vim.api.nvim_create_autocmd("WinEnter", {
        group = self._pwin_augroup,
        callback = function()
            if self._closed then return end
            local win = vim.api.nvim_get_current_win()
            if win == self._pwin or win == self._lwin or win == self._vwin then return end
            local cfg = vim.api.nvim_win_get_config(win)
            if not cfg.relative or cfg.relative == "" then self:_close_soon() end
        end,
    })
    vim.api.nvim_create_autocmd("VimResized", {
        group    = self._pwin_augroup,
        callback = function() vim.schedule(function() self:_relayout() end) end,
    })

    self._lbuf = ui.create_scratch_buffer(false, { modifiable = false }, function()
        self._lbuf = nil
        self:_close_soon()
    end)
    self._lwin = ui.create_window(self._lbuf, false, cfgs.list, function()
        self._lwin = nil
        self:_close_soon()
    end)
    local lwo = vim.wo[self._lwin][0]
    lwo.winhighlight = _WINHL
    lwo.wrap = false
    -- `wbr` is what `%=` stretches across the winbar; `eob` comes with the
    -- window's `style = "minimal"`, and setting 'fillchars' here would drop it.
    lwo.fillchars = "eob: ,wbr:" .. _RULE
    lwo.winbar = self:_status_winbar()
end

--- Put up the preview float. It exists only while the preview is shown, so it
--- is created when `<C-t>` asks for it rather than with the picker.
---@return nil
function Picker:_create_preview_window()
    if self._vwin or not self._preview_item then return end
    local cfgs = self:_float_cfgs()

    -- 'hide', not the scratch default 'wipe': the placeholder goes hidden every
    -- time a real preview buffer takes over the window.
    self._vbuf = ui.create_scratch_buffer(false, { modifiable = false, bufhidden = "hide" }, function()
        self._vbuf = nil
    end)

    local opts = { buffer = self._vbuf, nowait = true, silent = true }
    vim.keymap.set("n", "<CR>", function() self:confirm() end, opts)
    vim.keymap.set("n", "<Esc>", function() self:close(nil) end, opts)
    vim.keymap.set("n", "<C-t>", function() self:toggle_preview() end, opts)
    vim.keymap.set("n", "<C-e>", function() self:toggle_expanded() end, opts)

    self._vwin, self._vwin_augroup = ui.create_window(self._vbuf, false, cfgs.preview, function()
        self._vwin = nil
        if self._vbuf then
            vim.api.nvim_buf_delete(self._vbuf, { force = true })
            self._vbuf = nil
        end
        self:_close_soon()
    end)

    local vwo = vim.wo[self._vwin][0]
    vwo.wrap = true
    vwo.winhighlight = _WINHL
    vwo.conceallevel = 3
end

--- Take the preview float down.
---@return nil
function Picker:_destroy_preview_window()
    self:release_external_preview_buf()

    local win, buf = self._vwin, self._vbuf
    self._vwin, self._vbuf = nil, nil
    if self._vwin_augroup then
        pcall(vim.api.nvim_del_augroup_by_id, self._vwin_augroup)
        self._vwin_augroup = nil
    end
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
    end
end

---@param mode string|string[]
---@param lhs string
---@param rhs fun()
---@param buffer integer?
---@return nil
local function _map(mode, lhs, rhs, buffer)
    vim.keymap.set(mode, lhs, rhs, {
        buffer = buffer,
        nowait = true,
        silent = true,
    })
end

---@return nil
function Picker:_setup_input()
    ---Step the selection by `delta`, with no selection starting from the end
    ---nearest it.
    ---@param delta 1|-1
    local function step(delta)
        self:move_cursor((self:get_cursor() or (delta > 0 and 0 or 1)) + delta)
    end

    _map({ "i", "n" }, "<CR>", function() self:confirm() end, self._pbuf)
    _map("n", "<Esc>", function() self:close(nil) end, self._pbuf)
    _map("i", "<C-c>", function() self:close(nil) end, self._pbuf)

    _map({ "i", "n" }, "<C-n>", function() step(1) end, self._pbuf)
    _map({ "i", "n" }, "<C-p>", function() step(-1) end, self._pbuf)
    _map({ "i", "n" }, "<Down>", function() step(1) end, self._pbuf)
    _map({ "i", "n" }, "<Up>", function() step(-1) end, self._pbuf)

    -- Half a page is Neovim's own <C-u>/<C-d> run in the list window. Setting
    -- the cursor alone would only ask Neovim to keep it visible, and its choice
    -- between pinning it near the top and re-centering it alternates at half a
    -- page. The row it lands on then goes back through `move_cursor`, which
    -- does not move it again but runs the marker, counter, preview and
    -- `on_cursor`.
    ---@param dir 1|-1
    ---@return fun()
    local function half_page(dir)
        return function()
            local win = self._lwin
            if not win or not vim.api.nvim_win_is_valid(win) then return end
            local before = self:get_cursor()
            if not before or #self._items == 0 then return end

            vim.api.nvim_win_call(win, function()
                vim.cmd("normal! " .. (dir > 0 and "\4" or "\21"))
            end)

            local row = self:get_cursor()
            if row and row ~= before then self:move_cursor(row, true, true) end
        end
    end

    _map({ "i", "n" }, "<C-d>", half_page(1), self._pbuf)
    _map({ "i", "n" }, "<C-u>", half_page(-1), self._pbuf)

    if self._preview_item then
        _map({ "i", "n" }, "<C-t>", function() self:toggle_preview() end, self._pbuf)
    end
    _map({ "i", "n" }, "<C-e>", function() self:toggle_expanded() end, self._pbuf)
    _map({ "i", "n" }, "<C-l>", function() self:_cycle_focus() end, self._pbuf)

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer   = self._pbuf,
        callback = function() self:_apply_prompt() end,
    })

    -- Reachable by clicking into the list; keep the decisive keys working there.
    _map("n", "<CR>", function() self:confirm() end, self._lbuf)
    _map("n", "<Esc>", function() self:close(nil) end, self._lbuf)
    if self._preview_item then
        _map("n", "<C-t>", function() self:toggle_preview() end, self._lbuf)
    end
    _map("n", "<C-e>", function() self:toggle_expanded() end, self._lbuf)
    _map("n", "<C-l>", function() self:_cycle_focus() end, self._lbuf)

    -- With the focus on the list, the cursor is moved by ordinary motions -- j,
    -- k, the mouse -- and not through `move_cursor`, so the marker and the
    -- counter have to follow the cursor it actually landed on.
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer   = self._lbuf,
        callback = function()
            if self._closed or not self._lbuf then return end
            self:_render_selection()
        end,
    })
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
        -- Rewriting the line can take the marker's extmark with it.
        self:_render_prompt_marker()
    end

    if text == self._query then return end
    self._query = text
    self:_render_matches()
end

--- Filter `_entries` by the query and draw the result.
---@return nil
function Picker:_render_matches()
    if self._query == "" then
        self:set_items(self._entries)
        return
    end

    -- Matched over `{label, i}` dictionaries rather than the entries themselves:
    -- matchfuzzypos round-trips its input through Vimscript, which would copy
    -- (and so break the identity of) the caller's items.
    local result    = vim.fn.matchfuzzypos(self._pool, self._query, { key = "label" })
    local hits      = result[1]
    local positions = result[2]

    -- matchfuzzypos returns hits best-score-first. Unless sorting is asked for,
    -- put them back in the caller's order: a `vim.ui.select` list is usually
    -- already ordered, and rows jumping around as the query grows is hard to read.
    local order = {}
    for row = 1, #hits do
        order[row] = row
    end
    if not M.config.sort then
        table.sort(order, function(a, b) return hits[a].i < hits[b].i end)
    end

    local items = {}
    for row, hit_row in ipairs(order) do
        local entry = self._entries[hits[hit_row].i]
        items[row] = {
            label     = entry.label,
            item      = entry.item,
            idx       = entry.idx,
            positions = positions[hit_row],
        }
    end

    self:set_items(items)
end

--- Draw `items` and reset the highlight to the first row.
---@param items keystone.select.Entry[]
---@return nil
function Picker:set_items(items)
    self._items = items
    if not self._lbuf then return end

    local lines = {}
    for row, item in ipairs(items) do
        lines[row] = _PREFIX .. item.label
    end

    vim.bo[self._lbuf].modifiable = true
    vim.api.nvim_buf_set_lines(self._lbuf, 0, -1, false, lines)
    vim.bo[self._lbuf].modifiable = false

    vim.api.nvim_buf_clear_namespace(self._lbuf, _NS_MATCH, 0, -1)
    for row, item in ipairs(items) do
        local chunks = _chunks(item.label, item.positions)
        if chunks then
            local col = #_PREFIX
            for _, chunk in ipairs(chunks) do
                local text, hl = chunk[1], chunk[2]
                if text and #text > 0 then
                    if hl then
                        vim.api.nvim_buf_set_extmark(self._lbuf, _NS_MATCH, row - 1, col, {
                            end_col  = col + #text,
                            hl_group = hl,
                        })
                    end
                    col = col + #text
                end
            end
        end
    end

    if self._lwin and vim.api.nvim_win_is_valid(self._lwin) then
        vim.wo[self._lwin][0].cursorline = #items > 0
    end

    self:move_cursor(1, true, true)
end

--- The list's winbar: the rule below the prompt, with the position counter at
--- its right end. The rule is the `wbr` fill char stretched by `%=`, so the
--- winbar is never empty.
---@return string
function Picker:_status_winbar()
    local total = #self._items
    local text  = total > 0 and string.format(" %d/%d", self:get_cursor() or 1, total) or ""
    return "%#" .. _HL_RULE .. "#%=" .. text:gsub("%%", "%%%%")
end

---@return nil
function Picker:render_status()
    if not (self._lwin and vim.api.nvim_win_is_valid(self._lwin)) then return end
    vim.wo[self._lwin][0].winbar = self:_status_winbar()
end

---@return nil
function Picker:render_cursor()
    if not self._lbuf then return end
    vim.api.nvim_buf_clear_namespace(self._lbuf, _NS_CURSOR, 0, -1)
    local total = #self._items
    if total == 0 then
        self:render_status()
        return
    end
    local cur = self:get_cursor() or 1
    vim.api.nvim_buf_set_extmark(self._lbuf, _NS_CURSOR, cur - 1, 0, {
        virt_text     = { { "❯ ", "Special" } },
        virt_text_pos = "overlay",
        priority      = 100,
    })
end

---@return integer?
function Picker:get_cursor()
    if not self._lwin or not vim.api.nvim_win_is_valid(self._lwin) then return nil end
    return vim.api.nvim_win_get_cursor(self._lwin)[1]
end

--- Draw the marker, the counter and the preview for the row the list window's
--- cursor is on.
---@return nil
function Picker:_render_selection()
    self:render_cursor()
    self:render_status()
    self:update_preview()
end

--- Move the highlight to `row`, wrapping around the ends unless `clamp`.
---@param row integer
---@param force boolean?
---@param clamp boolean?
---@return nil
function Picker:move_cursor(row, force, clamp)
    local total = #self._items
    if total == 0 then
        self:render_cursor()
        self:render_status()
        self:update_preview()
        return
    end
    if not self._lwin or not vim.api.nvim_win_is_valid(self._lwin) then return end
    if not self._lbuf then return end

    if clamp then
        row = _clamp(row, 1, total)
    else
        if row > total then row = 1 end
        if row < 1 then row = total end
    end

    if not force and row == self:get_cursor() then return end

    -- Clear the old marker and hide 'cursorline' while the window scrolls to the
    -- new row: otherwise each row the jump passes over is drawn with them.
    vim.api.nvim_buf_clear_namespace(self._lbuf, _NS_CURSOR, 0, -1)
    vim.wo[self._lwin][0].cursorline = false

    vim.api.nvim_win_set_cursor(self._lwin, { row, 0 })

    self:_render_selection()
    vim.wo[self._lwin][0].cursorline = true
end

--- Show the highlighted item's preview, or the placeholder when it has none.
---@return nil
function Picker:update_preview()
    if self._closed or not (self._vwin and self._vbuf) then return end

    local entry   = self._items[self:get_cursor() or 0]
    local preview = entry and self._preview_item and self._preview_item(entry.item) or nil

    self:_restore_preview_buf()

    if preview and preview.buf and vim.api.nvim_buf_is_valid(preview.buf) then
        self._external_buf = preview.buf
        vim.api.nvim_win_set_buf(self._vwin, preview.buf)
        self:_reset_preview_winhl()
        _apply_preview_pos(self._vwin, preview.buf, preview.pos, preview.pos_end)
        return
    end

    vim.bo[self._vbuf].modifiable = true
    vim.api.nvim_buf_set_lines(self._vbuf, 0, -1, false, entry and { "", "  No preview" } or {})
    vim.bo[self._vbuf].modifiable = false
    vim.api.nvim_buf_clear_namespace(self._vbuf, _NS_PREVIEW, 0, -1)
    vim.api.nvim_win_set_cursor(self._vwin, { 1, 0 })
end

--- Show the preview window's own buffer again, undoing a caller buffer that was
--- swapped in, and take keystone's marks off that buffer.
---@return nil
function Picker:_restore_preview_buf()
    if not self._external_buf then return end
    if self._vwin and vim.api.nvim_win_is_valid(self._vwin) then
        pcall(vim.api.nvim_win_set_buf, self._vwin, self._vbuf)
        self:_reset_preview_winhl()
    end
    self:release_external_preview_buf()
end

---@return nil
function Picker:release_external_preview_buf()
    local buf = self._external_buf
    self._external_buf = nil
    if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_clear_namespace, buf, _NS_PREVIEW, 0, -1)
    end
end

---@return nil
function Picker:_reset_preview_winhl()
    vim.wo[self._vwin][0].winhighlight = _WINHL
end

--- Show the preview on the right half of the frame, or take it down.
---@return nil
function Picker:toggle_preview()
    if self._closed or not self._preview_item then return end

    if self._vwin then
        self:_destroy_preview_window()
        self:_apply_layout()
        return
    end

    self:_apply_layout(true)
    self:_create_preview_window()
    self:update_preview()
end

--- Fill the screen with the frame, or go back to the bar. A preview that is
--- showing stays on the right half, and grows with the frame.
---@return nil
function Picker:toggle_expanded()
    if self._closed then return end
    self._expanded = not self._expanded
    self:_apply_layout()
end

--- Move `win` to `cfg`, unless it already sits there.
---@param win integer?
---@param cfg table
---@return boolean moved
function Picker:_resize_window(win, cfg)
    if not win or not vim.api.nvim_win_is_valid(win) then return false end
    local cur = vim.api.nvim_win_get_config(win)
    if cur.relative == cfg.relative
        and cur.row == cfg.row
        and cur.col == cfg.col
        and cur.width == cfg.width
        and cur.height == cfg.height then
        return false
    end
    vim.api.nvim_win_set_config(win, cfg)
    return true
end

---@param cfgs table<string, table>
---@return nil
function Picker:_resize_windows(cfgs)
    self:_resize_window(self._pwin, cfgs.prompt)
    self:_resize_window(self._lwin, cfgs.list)
    if self._vwin then self:_resize_window(self._vwin, cfgs.preview) end
end

--- Settle the layout for the current editor size and view, and move the floats.
--- `preview` overrides whether the right half is reserved, for a caller that is
--- about to create or has just destroyed the preview window.
---@param preview boolean?
---@return nil
function Picker:_apply_layout(preview)
    if preview == nil then preview = self._vwin ~= nil end
    self._layout = _build_layout(M.config.height_ratio, M.config.preview_ratio, self._expanded, preview)
    self:_resize_windows(self:_float_cfgs())
end

---@return nil
function Picker:_relayout()
    if self._closed then return end
    self:_apply_layout()
end

--- Move the focus between the prompt and the list. Insert mode is left behind
--- on the way out of the prompt and entered again on the way back. The preview
--- is left out of the cycle: it can be showing a buffer the picker does not
--- own, and binding a key on it would be stepping into someone else's window.
---@return nil
function Picker:_cycle_focus()
    if self._closed then return end

    local wins = {}
    for _, win in ipairs({ self._pwin, self._lwin }) do
        if win and vim.api.nvim_win_is_valid(win) then wins[#wins + 1] = win end
    end
    if #wins == 0 then return end

    local cur = vim.api.nvim_get_current_win()
    local idx = 0
    for i, win in ipairs(wins) do
        if win == cur then
            idx = i
            break
        end
    end

    -- Insert mode is global, not per window: without this the next keystroke
    -- would still be inserted, now into the list buffer.
    vim.cmd("stopinsert")

    local next_win = wins[idx % #wins + 1]
    vim.api.nvim_set_current_win(next_win)
    if next_win == self._pwin then vim.cmd("startinsert") end
end

---@return nil
function Picker:_close_soon()
    if self._closed then return end
    vim.schedule(function() self:close(nil) end)
end

---@return nil
function Picker:confirm()
    local cur  = self:get_cursor()
    local item = cur and self._items[cur] or nil
    self:close(item)
end

--- Tear the picker down and report `entry` (or an abort, when nil). Every exit
--- path -- confirm, cancel, a window being closed from outside -- lands here.
---@param entry keystone.select.Entry?
---@return nil
function Picker:close(entry)
    if self._closed then return end
    self._closed = true
    if _active == self then _active = nil end

    -- The floats outlive this call by a tick, so their autocmds go now: each one
    -- expects a picker that is still open.
    if self._pwin_augroup then pcall(vim.api.nvim_del_augroup_by_id, self._pwin_augroup) end
    self._pwin_augroup = nil
    if self._vwin_augroup then pcall(vim.api.nvim_del_augroup_by_id, self._vwin_augroup) end
    self._vwin_augroup = nil

    self:release_external_preview_buf()

    -- Leaving insert mode steps the cursor one column left, and `:stopinsert`
    -- only takes effect once this returns -- so the floats have to outlive it,
    -- or that step lands in the window the focus falls back to.
    vim.cmd("stopinsert!")
    vim.schedule(function()
        for _, win in ipairs({ self._pwin, self._lwin, self._vwin }) do
            if win and vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
            end
        end
        for _, buf in ipairs({ self._pbuf, self._lbuf, self._vbuf }) do
            if buf and vim.api.nvim_buf_is_valid(buf) then
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

    if _active then _active:close(nil) end
    _active = Picker.new(entries, opts, on_choice)
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

--- Install this picker as `vim.ui.select`. Everything that prompts for a choice
--- -- keystone's own commands, the LSP's code actions, other plugins -- goes
--- through it from here on.
---@param opts keystone.select.Config?
function M.setup(opts)
    _setup = true
    cfgutil.apply(M.config, _default_config, opts)
    if not M.config.enabled then return end

    vim.ui.select = M.select
end

return M
