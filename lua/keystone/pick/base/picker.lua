local Spinner            = require("keystone.util.Spinner")
local common             = require("keystone.util.timer")
local uitool             = require("keystone.util.uitool")
local floatwin           = require("keystone.util.floatwin")
local layouts            = require("keystone.pick.base.layouts")
local queryflags         = require("keystone.pick.base.queryflags")
local pickertools        = require("keystone.pick.base.pickertools")

---@mod keystone.picker
---@brief Floating async picker with fuzzy filtering and optional preview.

local M                  = {}

local _NS_CURSOR         = vim.api.nvim_create_namespace("keystone_PickerCursor")
local _NS_CONTENT        = vim.api.nvim_create_namespace("keystone_PickerContent")
local _NS_SPINNER        = vim.api.nvim_create_namespace("keystone_PickerSpinner")
local _NS_PREVIEW        = vim.api.nvim_create_namespace("keystone_PickerPreview")

local _antiflicker_delay = 200


---@class keystone.picker.ItemData
---@field filepath string?
---@field lnum number?
---@field col number?
---@field [string] any

---@class keystone.Picker.Item
---@field label_chunks {[1]:string,[2]:string?}[]?
---@field virt_lines? {[1]:string,[2]:string?}[][]
---@field score number?
---@field data keystone.picker.ItemData
---@field initial boolean?

---@class keystone.picker.ListItem
---@field label_chunks {[1]:string,[2]:string?}[]?
---@field virt_lines? {[1]:string,[2]:string?}[][]
---@field score number
---@field data keystone.picker.ItemData

---@alias keystone.Picker.Callback fun(data:keystone.picker.ItemData?)

---@class keystone.Picker.FetcherOpts
---@field list_width number
---@field list_height number
---@field parsed keystone.queryflags.ParseResult?

---@class keystone.Picker.QueryHistoryProvider
---@field load fun():string[]
---@field store fun(hist:string[])?

---@alias keystone.Picker.Fetcher fun(query:string,opts:keystone.Picker.FetcherOpts):keystone.Picker.Item[]?,number?
---@alias keystone.Picker.Finder fun(query:string,flags:table,opts:keystone.Picker.FetcherOpts,callback:fun(new_items:keystone.Picker.Item[]?)):fun()?
---@alias keystone.Picker.QueryHighlighter fun(query:string): {start:integer, finish:integer, hl:string}[]

---@class keystone.Picker.AsyncPreviewOpts
---@field viewport_width number
---@field viewport_height number

---@alias keystone.Picker.AsyncPreviewData {content:string|string[]|nil,filetype:string?,filepath:string?,pos?:{[1]:integer,[2]:integer},pos_end?:{[1]:integer,[2]:integer},error_msg:string?,bufnr:integer?}
---@alias keystone.Picker.AsyncPreviewLoader fun(data:keystone.picker.ItemData, opts:keystone.Picker.AsyncPreviewOpts, callback:fun(preview:keystone.Picker.AsyncPreviewData?)):fun()?

---@class keystone.Picker.opts
---@field prompt string
---@field flags keystone.queryflags.FlagDef[]?
---@field finder keystone.Picker.Finder?
---@field enable_preview boolean?
---@field previewer keystone.Picker.AsyncPreviewLoader?
---@field history_provider keystone.Picker.QueryHistoryProvider?
---@field quickfix_formatter (fun(data:any):vim.quickfix.entry?)?
---@field height_ratio number?
---@field width_ratio number?
---@field list_wrap boolean?
---@field enable_list_sep boolean?
---@field initial_query  string?

---@class keystone.Picker.Layout
---@field prompt_row number
---@field prompt_col number
---@field prompt_width number
---@field prompt_height number
---@field list_row number
---@field list_col number
---@field list_width number
---@field list_height number
---@field preview_row number
---@field preview_col number
---@field preview_width number
---@field preview_height number


local function _show_help()
	local help_text = [[
`<CR>`        Confirm
`<Esc>`       Close picker
`<C-n>`       Next item
`<C-p>`       Previous item
`<C-d>`       Scroll down half page
`<C-u>`       Scroll up half page
`<C-j>`       Next search history entry
`<C-k>`       Previous search history entry
`<C-q>`       Send results to quickfix list
`<C-r><C-w>`  Insert original <cword>
`g?`          Show help
]]
	floatwin.open(help_text, {
		title = "Picker",
		is_markdown = true,
	})
end

---@type fun(v:number,min:number,max:number):number
local function _clamp(v, min, max)
	return math.max(min, math.min(max, v))
end

local function _key_opts_of(buf)
	assert(buf and vim.api.nvim_buf_is_valid(buf))
	return { buffer = buf, nowait = true, silent = true }
end

---@param modifiable boolean
---@param on_delete fun()
---@param bufhidden 'hide'|'wipe'?
local function _create_buffer(modifiable, on_delete, bufhidden)
	return uitool.create_scratch_buffer(false, {
			modifiable = modifiable,
			spelloptions = "noplainbuffer",
			bufhidden = bufhidden,
		},
		on_delete)
end

---@param win integer
---@param lnum integer
---@param col integer?
local function _place_preview_cursor(win, lnum, col)
	vim.api.nvim_win_call(win, function()
		if not col or col < 0 then col = 0 end
		vim.api.nvim_win_set_cursor(win, { lnum, col })
		vim.cmd("normal! zz")
	end)
end

---@param win integer
---@param buf integer
---@param pos {[1]:integer,[2]:integer}?
---@param pos_end {[1]:integer,[2]:integer}?
local function _apply_preview_pos(win, buf, pos, pos_end)
	vim.api.nvim_buf_clear_namespace(buf, _NS_PREVIEW, 0, -1)
	if not pos then
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		return
	end
	local lnum = _clamp(pos[1], 1, vim.api.nvim_buf_line_count(buf))
	_place_preview_cursor(win, lnum, pos[2])
	if pos_end then
		vim.api.nvim_buf_set_extmark(buf, _NS_PREVIEW, lnum - 1, pos[2], {
			end_row  = _clamp(pos_end[1], lnum, vim.api.nvim_buf_line_count(buf) + 1) - 1,
			end_col  = pos_end[2],
			hl_group = "Visual",
			hl_eol   = true,
			hl_mode  = "blend",
		})
	else
		vim.api.nvim_buf_set_extmark(buf, _NS_PREVIEW, lnum - 1, 0, {
			end_row  = lnum,
			hl_group = "Visual",
			hl_eol   = true,
			hl_mode  = "blend",
		})
	end
end

---@param msg string
---@param width number
---@param height number
---@return string[]
local function _center_for_previewer(msg, width, height)
	local pad_left = math.max(0, math.floor((width - #msg) / 2) + 1)
	local centered = string.rep(" ", pad_left) .. msg
	local pad_top = math.max(0, math.floor((height + 1) / 2))

	local lines = {}
	for _ = 1, pad_top do
		table.insert(lines, "")
	end
	table.insert(lines, centered)
	return lines
end


---@param items keystone.picker.ListItem[]
local function _sort_by_score(items)
	local with_score = {}
	local no_score = {}
	for _, item in ipairs(items) do
		if item.score ~= nil then
			table.insert(with_score, item)
		else
			table.insert(no_score, item)
		end
	end
	if #with_score == 0 then
		return no_score
	end
	table.sort(with_score, function(a, b)
		return a.score > b.score
	end)
	vim.list_extend(with_score, no_score)
	return with_score
end

local _last_session  = nil
local _active_picker = nil

---@param a table
---@param b table
---@return boolean
local function _flags_equal(a, b)
	for k, v in pairs(a) do
		if type(v) == "table" then
			if type(b[k]) ~= "table" or #v ~= #b[k] then return false end
			for i, x in ipairs(v) do if b[k][i] ~= x then return false end end
		elseif b[k] ~= v then
			return false
		end
	end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end

---@param entry string
---@return string
local function _decode_history(entry)
	-- Older entries were stored as JSON `{q=..,f=..}`; decode them for compatibility.
	local ok, t = pcall(vim.json.decode, entry)
	if ok and type(t) == "table" then
		return t.q or ""
	end
	return entry
end

---@param item keystone.picker.ListItem
local function _item_label(item)
	if not item.label_chunks then return "" end
	local parts = {}
	for _, chunk in ipairs(item.label_chunks) do
		table.insert(parts, chunk[1] or "")
	end
	return table.concat(parts):gsub("\n", " ")
end

---@class keystone.util.Picker
---@field new fun(self: keystone.util.Picker,opts:keystone.Picker.opts,callback:keystone.Picker.Callback) : keystone.util.Picker
---@field opts keystone.Picker.opts
---@field callback keystone.Picker.Callback
---@field preview_enabled boolean
---@field layout keystone.Picker.Layout
---@field pbuf integer?
---@field lbuf integer?
---@field vbuf integer?
---@field pwin integer?
---@field lwin integer?
---@field vwin integer?
---@field spinner keystone.util.Spinner?
---@field closed boolean
---@field list_items keystone.picker.ListItem[]
---@field async_fetch_context number
---@field async_fetch_cancel fun()?
---@field async_preview_context number
---@field async_preview_cancel fun()?
---@field _preview_external_buf integer?
---@field preview_timer table?
---@field resize_augroup number?
---@field current_query string?
---@field history string[]
---@field history_idx number
local Picker = {}
Picker.__index = Picker

function Picker:new(...)
	local obj = setmetatable({}, self)
	if obj.init then obj:init(...) end
	return obj
end

---@param opts keystone.Picker.opts
---@param callback keystone.Picker.Callback
function Picker:init(opts, callback)
	vim.validate("opts", opts, "table")
	vim.validate("callback", callback, "function")

	self.opts                  = opts and vim.deepcopy(opts) or {}
	self.opts.flags            = self.opts.flags or {}
	self.callback              = callback

	self.preview_enabled       = opts.enable_preview
	self.preview_default       = "visible" ---@type "visible"|"hidden"

	self.list_items            = {} ---@type keystone.picker.ListItem[]

	self.closed                = false

	self.async_fetch_context   = 0
	self.async_fetch_cancel    = nil

	self.async_preview_context = 0
	self.async_preview_cancel  = nil

	self.spinner               = nil

	self.query_text            = ""

	self.history               = {}
	self.history_idx           = 0
	self.history_saved_query   = nil

	if self.opts.history_provider then
		self.history = self.opts.history_provider.load() or {}
		self.history_idx = #self.history + 1
	end

	local cword_ok, cword = pcall(vim.fn.expand, "<cword>")
	self.original_cword = tostring(cword_ok and (type(cword) == "table" and cword[1] or cword) or "")

	_active_picker = self

	self:setup_ui()
	self:setup_input()

	assert(self.pwin)
	vim.api.nvim_set_current_win(self.pwin)

	if type(opts.initial_query) == "string" and opts.initial_query ~= "" then
		self:set_prompt_text(opts.initial_query .. " " --[[@as string]])
	else
		self:run_fetch()
	end
	vim.schedule(function()
		vim.cmd("startinsert!")
	end)
end

---@return nil
function Picker:setup_ui()
	local preview_action
	if self.preview_enabled and self.preview_default == "visible" then
		preview_action = "show_preview"
	end
	self:relayout(preview_action)

	assert(self.pbuf ~= nil)
	vim.keymap.set("i", "<C-r><C-w>", function()
		vim.api.nvim_feedkeys(
			vim.api.nvim_replace_termcodes(self.original_cword, true, false, true),
			"i", false
		)
	end, { buffer = self.pbuf, desc = "Page original <cword>" })
end

function Picker:toggle_preview()
	if not self.preview_enabled then return end
	self:relayout(self.vwin ~= nil and "hide_preview" or "show_preview")
end

---@param action "show_preview"|"hide_preview"|nil
function Picker:relayout(action)
	if self.closed then return end
	local opts = self.opts
	local title = opts.prompt and (" " .. opts.prompt .. " ") or ""

	if vim.fn.pumvisible() == 1 then
		vim.api.nvim_feedkeys(
			vim.api.nvim_replace_termcodes("<C-e>", true, false, true), "n", false
		)
	end

	local has_preview = (self.vwin ~= nil and action ~= "hide_preview") or action == "show_preview"

	self.layout = layouts.get_horizontal_layout {
		has_preview = has_preview,
		height_ratio = self.opts.height_ratio,
		width_ratio = self.opts.width_ratio,
	}

	if self.opts.enable_list_sep then
		self.list_sep_line = string.rep("─", self.layout.list_width)
	end

	local base_cfg = {
		relative = "editor",
		style = "minimal",
		border = "rounded"
	}

	local winhl = "NormalFloat:Normal,FloatBorder:Normal,FloatTitle:Title"

	if not self.pwin then
		if not self.pbuf then
			self.pbuf = _create_buffer(true, function()
				self.pbuf = nil
				if not self.closed then
					vim.schedule(function() self:close() end)
				end
			end)
		end
		local pwin_augroup
		self.pwin, pwin_augroup = uitool.create_window(self.pbuf, true, vim.tbl_extend("force", base_cfg, {
				row = self.layout.prompt_row,
				col = self.layout.prompt_col,
				width = self.layout.prompt_width,
				height = 1,
				title = title,
				title_pos = "center"
			}),
			function()
				self.pwin = nil
				if not self.closed then
					vim.schedule(function() self:close() end)
				end
			end)
		vim.wo[self.pwin].winhighlight = winhl
		vim.wo[self.pwin].wrap = false

		assert(type(pwin_augroup) == "number")
		vim.api.nvim_create_autocmd("WinEnter", {
			group = pwin_augroup,
			callback = function(_)
				local win = vim.api.nvim_get_current_win()
				assert(not self.closed)
				local cfg = vim.api.nvim_win_get_config(win)
				local is_float = cfg.relative and cfg.relative ~= ""
				if not is_float and win ~= self.pwin and win ~= self.lwin and win ~= self.vwin then
					vim.schedule(function()
						self:close()
					end)
				end
			end
		})
		vim.api.nvim_create_autocmd("VimResized", {
			group = pwin_augroup,
			callback = function()
				assert(not self.closed)
				vim.schedule(function()
					self:relayout()
				end)
			end
		})
	else
		vim.api.nvim_win_set_config(self.pwin, vim.tbl_extend("force", base_cfg, {
			row = self.layout.prompt_row,
			col = self.layout.prompt_col,
			width = self.layout.prompt_width,
			height = 1,
		}))
	end

	if not self.lwin then
		if not self.lbuf then
			self.lbuf = _create_buffer(false, function()
				self.lbuf = nil
				if not self.closed then
					vim.schedule(function() self:close() end)
				end
			end)
		end
		self.lwin = uitool.create_window(self.lbuf, false, vim.tbl_extend("force", base_cfg, {
				row = self.layout.list_row,
				col = self.layout.list_col,
				width = self.layout.list_width,
				height = self.layout.list_height
			}),
			function()
				self.lwin = nil
				if not self.closed then
					vim.schedule(function() self:close() end)
				end
			end)
		vim.wo[self.lwin].winhighlight = winhl
		vim.wo[self.lwin].wrap = self.opts.list_wrap ~= false
	else
		vim.api.nvim_win_set_config(self.lwin, vim.tbl_extend("force", base_cfg, {
			row = self.layout.list_row,
			col = self.layout.list_col,
			width = self.layout.list_width,
			height = self.layout.list_height,
		}))
	end

	if has_preview then
		if not self.vwin then
			if not self.vbuf then
				self.vbuf = _create_buffer(false, function()
					self.vbuf = nil
				end, "hide")
				local vbuf_key_opts = _key_opts_of(self.vbuf)
				vim.keymap.set("n", "<CR>", function() self:confirm() end, vbuf_key_opts)
				vim.keymap.set("n", "<Esc>", function() self:close() end, vbuf_key_opts)
			end
			self.vwin = uitool.create_window(self.vbuf, false, {
					relative = "editor",
					style = "minimal",
					border = "rounded",
					row = self.layout.preview_row,
					col = self.layout.preview_col,
					width = self.layout.preview_width,
					height = self.layout.preview_height,
				},
				function()
					self.vwin = nil
					if self.vbuf then
						vim.api.nvim_buf_delete(self.vbuf, { force = true })
						self.vbuf = nil
					end
				end)
			vim.wo[self.vwin].wrap = true
			vim.wo[self.vwin].winhighlight = winhl
		else
			vim.api.nvim_win_set_config(self.vwin, vim.tbl_extend("force", base_cfg, {
				row = self.layout.preview_row,
				col = self.layout.preview_col,
				width = self.layout.preview_width,
				height = self.layout.preview_height,
			}))
		end
		self:update_preview()
	else
		if self.vwin then
			vim.api.nvim_win_close(self.vwin, true)
			self.vwin = nil
		end
		if self.vbuf then
			vim.api.nvim_buf_delete(self.vbuf, { force = true })
			self.vbuf = nil
		end
	end
end

function Picker:render_prompt_highlight(query)
	if not self.pbuf then return end
	vim.api.nvim_buf_clear_namespace(self.pbuf, _NS_CONTENT, 0, -1)
	if #self.opts.flags == 0 then return end
	for _, h in ipairs(queryflags.highlight(self.opts.flags, query)) do
		vim.api.nvim_buf_set_extmark(self.pbuf, _NS_CONTENT, 0, h.start, {
			end_col  = h.finish,
			hl_group = h.hl,
		})
	end
end

---@param query string
---@param auto boolean?
function Picker:trigger_flag_completion(query, auto)
	if #self.opts.flags == 0 then return end
	if vim.fn.pumvisible() == 1 then return end
	if not self.pwin or not vim.api.nvim_win_is_valid(self.pwin) then return end
	if vim.fn.mode() ~= "i" then return end

	local col         = vim.api.nvim_win_get_cursor(self.pwin)[2]
	local completions = queryflags.get_completions(self.opts.flags, query, col, auto)
	if completions and #completions.items > 0 then
		vim.fn.complete(completions.startcol, completions.items)
	end
end

function Picker:render_position()
	if not self.pbuf then return end
	vim.api.nvim_buf_clear_namespace(self.pbuf, _NS_CURSOR, 0, -1)
	local total = #self.list_items
	if total == 0 then return end
	local cur = self:get_cursor() or 1
	local text = string.format("%d/%d", cur, total)
	vim.api.nvim_buf_set_extmark(self.pbuf, _NS_CURSOR, 0, 0, {
		virt_text = { { text, "NonText" } },
		virt_text_pos = "eol_right_align",
		hl_mode = "blend",
		priority = 50,
	})
end

function Picker:render_cursor()
	if not self.lbuf then return end
	vim.api.nvim_buf_clear_namespace(self.lbuf, _NS_CURSOR, 0, -1)
	local total = #self.list_items
	if total == 0 then
		vim.api.nvim_buf_clear_namespace(self.pbuf, _NS_CURSOR, 0, -1)
		return
	end
	local cur = self:get_cursor() or 1
	vim.api.nvim_buf_set_extmark(self.lbuf, _NS_CURSOR, cur - 1, 0, {
		virt_text = { { "❯ ", "Special" } },
		virt_text_pos = "overlay",
		priority = 100,
	})
end

---@return integer?
function Picker:get_cursor()
	if not self.lwin then return nil end
	return vim.api.nvim_win_get_cursor(self.lwin)[1]
end

---@param row integer
---@param force boolean?
---@param clamp boolean?
function Picker:move_cursor(row, force, clamp)
	if not force then
		if row == self:get_cursor() then return end
	end

	local total = #self.list_items
	if total == 0 then return end

	if clamp then
		row = _clamp(row, 1, total)
	else
		if row > total then row = 1 end
		if row < 1 then row = total end
	end

	vim.api.nvim_win_set_cursor(self.lwin, { row, 0 })

	self:render_cursor()
	self:render_position()
	self:update_preview()
end

---@return nil
function Picker:update_preview()
	self.async_preview_context = self.async_preview_context + 1
	local preview_context = self.async_preview_context
	local fetch_context = self.async_fetch_context

	if self.closed then return end
	if not self.vbuf then return end

	self:request_clear_preview()

	if self.async_preview_cancel then
		self.async_preview_cancel()
		self.async_preview_cancel = nil
	end

	local cursor = self:get_cursor()
	---@type keystone.picker.ListItem?
	local item = cursor and self.list_items[cursor] or nil
	if not item then return end

	local preview_width = math.max(0, self.layout.preview_width - 2) -- -2 for borders
	local preview_height = math.max(0, self.layout.preview_height - 2) -- -2 for borders

	local preview_fn = self.opts.previewer or pickertools.file_preview

	self.async_preview_cancel = preview_fn(
		item.data,
		{
			viewport_width = preview_width,
			viewport_height = preview_height,
		},
		vim.schedule_wrap(function(preview)
			if self.closed or preview_context ~= self.async_preview_context or fetch_context ~= self.async_fetch_context then
				return
			end
			preview = preview or {}
			self:cancel_clear_preview_req()

			if preview.bufnr and vim.api.nvim_buf_is_valid(preview.bufnr) then
				if self.vwin and vim.api.nvim_win_is_valid(self.vwin) then
					self._preview_external_buf = preview.bufnr
					vim.api.nvim_win_set_buf(self.vwin, preview.bufnr)
					_apply_preview_pos(self.vwin, preview.bufnr, preview.pos, preview.pos_end)
				end
				return
			end

			if self._preview_external_buf and self.vwin and vim.api.nvim_win_is_valid(self.vwin) then
				pcall(vim.api.nvim_win_set_buf, self.vwin, self.vbuf)
				self._preview_external_buf = nil
			end

			local content = preview.content
			local lines ---@type string[]
			if content then
				if type(content) == "string" then
					lines = vim.split(content, "\n")
				else
					lines = content
				end
			elseif preview.error_msg then
				lines = _center_for_previewer(preview.error_msg, preview_width, preview_height)
			else
				lines = _center_for_previewer("No preview", preview_width, preview_height)
			end
			lines = lines or {}
			if self.vbuf then
				vim.bo[self.vbuf].modifiable = true
				vim.api.nvim_buf_set_lines(self.vbuf, 0, -1, false, lines)
				vim.bo[self.vbuf].modifiable = false
				local filetype = content and (preview.filetype
					or (preview.filepath and vim.filetype.match({ filename = preview.filepath }))
					or "") or ""
				vim.bo[self.vbuf].filetype = filetype
				_apply_preview_pos(self.vwin, self.vbuf, content and preview.pos or nil,
					content and preview.pos_end or nil)
			end
		end)
	)
end

function Picker:start_spinner()
	if self.spinner then return end

	self.spinner = Spinner:new {
		interval = 100,
		on_update = function(frame)
			if not self.pbuf then return end
			vim.api.nvim_buf_clear_namespace(self.pbuf, _NS_SPINNER, 0, -1)
			vim.api.nvim_buf_set_extmark(self.pbuf, _NS_SPINNER, 0, 0, {
				virt_text = { { frame .. " ", "NonText" } },
				virt_text_pos = "eol_right_align",
				priority = 1,
			})
		end
	}

	self.spinner:start()
end

function Picker:stop_spinner()
	if self.spinner then
		self.spinner:stop()
		self.spinner = nil
	end

	if self.pbuf then
		vim.api.nvim_buf_clear_namespace(self.pbuf, _NS_SPINNER, 0, -1)
	end
end

---@param immediate  boolean?
function Picker:request_clear_preview(immediate)
	local clear = function()
		if self.vbuf and not self.closed then
			if self._preview_external_buf and self.vwin and vim.api.nvim_win_is_valid(self.vwin) then
				pcall(vim.api.nvim_win_set_buf, self.vwin, self.vbuf)
				self._preview_external_buf = nil
			end
			vim.bo[self.vbuf].modifiable = true
			vim.api.nvim_buf_set_lines(self.vbuf, 0, -1, false, {})
			vim.bo[self.vbuf].modifiable = false
			vim.api.nvim_buf_clear_namespace(self.vbuf, _NS_PREVIEW, 0, -1)
		end
	end
	if immediate then
		self:cancel_clear_preview_req()
		clear()
	elseif not self.preview_timer then
		self.preview_timer = vim.defer_fn(function()
			self.preview_timer = nil
			clear()
		end, _antiflicker_delay)
	end
end

function Picker:cancel_clear_preview_req()
	self.preview_timer = common.stop_and_close_timer(self.preview_timer)
end

function Picker:clear_list()
	self.list_items = {}

	vim.bo[self.lbuf].modifiable = true
	vim.api.nvim_buf_set_lines(self.lbuf, 0, -1, false, {})
	vim.bo[self.lbuf].modifiable = false
	vim.wo[self.lwin].cursorline = false

	vim.api.nvim_buf_clear_namespace(self.lbuf, _NS_CONTENT, 0, -1)
	self:request_clear_preview()
	self:render_cursor()
	self:render_position()
end

---@param items keystone.Picker.Item[]?
function Picker:set_items(items)
	items = _sort_by_score(items or {})

	local prefix = "  "

	self.list_items = {}

	local lines = {}
	local extmarks = {}

	for row_idx, item in ipairs(items) do
		---@type keystone.picker.ListItem
		local list_item = {
			score = item.score,
			data = item.data,
			label_chunks = item.label_chunks,
			virt_lines = item.virt_lines,
		}

		local label = _item_label(item)

		table.insert(self.list_items, list_item)

		local row = row_idx - 1
		table.insert(lines, prefix .. label)

		if item.label_chunks then
			local col = #prefix

			for _, chunk in ipairs(item.label_chunks) do
				local text, hl = chunk[1], chunk[2]

				if text and #text > 0 then
					if hl then
						table.insert(extmarks, {
							ns = _NS_CONTENT,
							row = row,
							col = col,
							opts = {
								end_col = col + #text,
								hl_group = hl,
							},
						})
					end

					col = col + #text
				end
			end
		end

		local vlines = {}

		if item.virt_lines and #item.virt_lines > 0 then
			for _, line in ipairs(item.virt_lines) do
				local vl = { { prefix } }
				vim.list_extend(vl, line)
				table.insert(vlines, vl)
			end
		end

		if self.opts.enable_list_sep then
			table.insert(vlines, { { self.list_sep_line, "NonText" } })
		end

		if #vlines > 0 then
			table.insert(extmarks, {
				ns = _NS_CONTENT,
				row = row,
				col = 0,
				opts = {
					virt_lines = vlines,
					hl_mode = "blend",
				},
			})
		end
	end

	vim.bo[self.lbuf].modifiable = true

	vim.api.nvim_buf_set_lines(self.lbuf, 0, -1, false, lines)

	vim.api.nvim_buf_clear_namespace(self.lbuf, _NS_CONTENT, 0, -1)

	for _, mark in ipairs(extmarks) do
		vim.api.nvim_buf_set_extmark(
			self.lbuf,
			mark.ns,
			mark.row,
			mark.col,
			mark.opts
		)
	end
	vim.bo[self.lbuf].modifiable = false
	vim.wo[self.lwin].cursorline = #self.list_items > 0
end

function Picker:run_fetch()
	local query_text   = self.query_text
	self.current_query = query_text

	if self.async_fetch_cancel then
		self.async_fetch_cancel()
		self.async_fetch_cancel = nil
	end

	self:stop_spinner()
	self:request_clear_preview()

	local fetch_opts = {
		list_width  = math.max(1, self.layout.list_width - 2),
		list_height = math.max(1, self.layout.list_height - 2),
	}

	local clean_query, flags
	if #self.opts.flags > 0 then
		local parsed      = queryflags.parse(self.opts.flags, query_text)
		clean_query       = parsed.query
		flags             = parsed.flags
		fetch_opts.parsed = parsed
	else
		clean_query = query_text
		flags       = {}
	end

	if clean_query == self._last_clean_query and _flags_equal(flags, self._last_flags or {}) then
		return
	end
	self._last_clean_query   = clean_query
	self._last_flags         = flags

	self.async_fetch_context = self.async_fetch_context + 1
	local context            = self.async_fetch_context

	local complete           = false

	self.async_fetch_cancel  = self.opts.finder(
		clean_query,
		flags,
		fetch_opts,
		function(new_items)
			if complete or self.closed or context ~= self.async_fetch_context then return end
			complete = true
			self:stop_spinner()
			if new_items and #new_items > 0 then
				local initial_data
				for _, item in ipairs(new_items) do
					if item.initial then
						initial_data = item.data
						break
					end
				end
				self:set_items(new_items)
				local target_row = 1
				if initial_data then
					for i, li in ipairs(self.list_items) do
						if li.data == initial_data then
							target_row = i
							break
						end
					end
				end
				self:move_cursor(target_row, true, true)
			else
				self:clear_list()
			end
		end
	)
	if not complete then
		assert(type(self.async_fetch_cancel) == "function",
			"finder with deferred result should return a function")
		self:start_spinner()
	end
end

function Picker:_apply_history_entry(q)
	self.query_text = q
	vim.api.nvim_buf_set_lines(self.pbuf, 0, -1, false, { q })
	vim.api.nvim_win_set_cursor(self.pwin, { 1, #q })
	self:render_prompt_highlight(q)
	self:run_fetch()
end

function Picker:history_prev()
	if not self.opts.history_provider or #self.history == 0 then return end

	if self.history_idx == #self.history + 1 then
		self.history_saved_query = self.query_text
	end

	local new_idx = math.max(1, self.history_idx - 1)
	if new_idx ~= self.history_idx then
		self.history_idx = new_idx
		self:_apply_history_entry(_decode_history(self.history[self.history_idx]))
	end
end

function Picker:history_next()
	if not self.opts.history_provider then return end

	local new_idx = self.history_idx + 1
	if new_idx <= #self.history then
		self.history_idx = new_idx
		self:_apply_history_entry(_decode_history(self.history[self.history_idx]))
	elseif new_idx == #self.history + 1 then
		self.history_idx         = new_idx
		local q                  = self.history_saved_query or ""
		self.history_saved_query = nil
		self:_apply_history_entry(q)
	end
end

function Picker:set_prompt_text(text)
	self.query_text = text
	vim.api.nvim_buf_set_lines(self.pbuf, 0, -1, false, { text })
	vim.api.nvim_win_set_cursor(self.pwin, { 1, #text })
	self:render_prompt_highlight(text)
	self:run_fetch()
end

function Picker:send_to_qf()
	if #self.list_items == 0 then return end
	local qf_entries = {} ---@type vim.quickfix.entry[]

	if self.opts.quickfix_formatter then
		for _, item in ipairs(self.list_items) do
			local entry = self.opts.quickfix_formatter(item.data)
			if entry then table.insert(qf_entries, entry) end
		end
	else
		for _, item in ipairs(self.list_items) do
			local data = item.data or {}
			---@type vim.quickfix.entry
			local entry = {
				text     = _item_label(item),
				filename = data.filepath,
				lnum     = data.lnum or 1,
				col      = data.col or 1,
			}
			table.insert(qf_entries, entry)
		end
	end
	if #qf_entries > 0 then
		self:close()
		vim.fn.setqflist(qf_entries, "r")
		vim.cmd("copen")
	end
end

function Picker:confirm()
	local cursor = self:get_cursor()
	---@type keystone.picker.ListItem?
	local list_item = cursor and self.list_items[cursor] or nil
	self:close(list_item and list_item.data or nil)
end

---@param selected_data keystone.picker.ItemData?
function Picker:close(selected_data)
	if self.closed then return end
	self.closed = true
	if _active_picker == self then _active_picker = nil end

	self:stop_spinner()

	self.preview_timer = common.stop_and_close_timer(self.preview_timer)

	if self.async_fetch_cancel then self.async_fetch_cancel() end
	if self.async_preview_cancel then self.async_preview_cancel() end

	local cursor      = self:get_cursor()
	local cursor_item = cursor and self.list_items[cursor]
	_last_session     = {
		cursor_index = cursor_item and cursor or nil,
		cursor_text  = cursor_item and _item_label(cursor_item) or nil,
		query        = self.query_text,
		opts         = self.opts,
		callback     = self.callback,
	}

	for _, w in pairs({ self.pwin, self.lwin, self.vwin }) do
		if vim.api.nvim_win_is_valid(w) then
			vim.api.nvim_win_close(w, true)
		end
	end

	for _, b in pairs({ self.pbuf, self.lbuf, self.vbuf }) do
		if vim.api.nvim_buf_is_valid(b) then
			vim.api.nvim_buf_delete(b, { force = true })
		end
	end

	if self.opts.history_provider then
		local entry = self.query_text
		if entry ~= "" and entry ~= self.history[#self.history] then
			table.insert(self.history, entry)
			if self.opts.history_provider.store then
				self.opts.history_provider.store(self.history)
			end
		end
	end

	vim.cmd("stopinsert!")
	vim.schedule(function()
		self.callback(selected_data)
	end)
end

function Picker:setup_input()
	do
		local pbuf_key_opts = _key_opts_of(self.pbuf)
		vim.keymap.set("n", "g?", _show_help, pbuf_key_opts)

		vim.keymap.set({ "i", "n" }, "<CR>", function() self:confirm() end, pbuf_key_opts)

		vim.keymap.set("n", "<Esc>", function() self:close() end, pbuf_key_opts)
		vim.keymap.set("i", "<C-c>", function() self:close() end, pbuf_key_opts)

		local expr_opts = vim.tbl_extend("force", pbuf_key_opts, { expr = true })

		vim.keymap.set("n", "<C-n>", function() self:move_cursor((self:get_cursor() or 0) + 1) end, pbuf_key_opts)
		vim.keymap.set("n", "<C-p>", function() self:move_cursor((self:get_cursor() or 1) - 1) end, pbuf_key_opts)

		vim.keymap.set("i", "<C-n>", function()
			if vim.fn.pumvisible() == 1 then return "<C-n>" end
			self:move_cursor((self:get_cursor() or 0) + 1)
			return ""
		end, expr_opts)
		vim.keymap.set("i", "<C-p>", function()
			if vim.fn.pumvisible() == 1 then return "<C-p>" end
			self:move_cursor((self:get_cursor() or 1) - 1)
			return ""
		end, expr_opts)

		vim.keymap.set("i", "<Down>", function()
			if vim.fn.pumvisible() == 1 then return "<Down>" end
			self:move_cursor((self:get_cursor() or 0) + 1)
			return ""
		end, expr_opts)
		vim.keymap.set("i", "<Up>", function()
			if vim.fn.pumvisible() == 1 then return "<Up>" end
			self:move_cursor((self:get_cursor() or 1) - 1)
			return ""
		end, expr_opts)

		vim.keymap.set({ "i", "n" }, "<C-d>", function()
			local cur = self:get_cursor()
			if cur then
				local step = math.floor(self.layout.list_height / 2)
				self:move_cursor(cur + step, false, true)
			end
		end, pbuf_key_opts)

		vim.keymap.set({ "i", "n" }, "<C-u>", function()
			local cur = self:get_cursor()
			if cur then
				local step = math.floor(self.layout.list_height / 2)
				self:move_cursor(cur - step, false, true)
			end
		end, pbuf_key_opts)

		vim.keymap.set("i", "<C-j>", function() self:history_next() end, pbuf_key_opts)
		vim.keymap.set("i", "<C-k>", function() self:history_prev() end, pbuf_key_opts)

		vim.keymap.set("n", "j", function() self:history_next() end, pbuf_key_opts)
		vim.keymap.set("n", "k", function() self:history_prev() end, pbuf_key_opts)

		vim.keymap.set({ "n", "i" }, "<C-q>", function() self:send_to_qf() end, pbuf_key_opts)

		vim.keymap.set("i", "<C-Space>", function()
			self:trigger_flag_completion(self.query_text, false)
		end, pbuf_key_opts)

		vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
			buffer = self.pbuf,
			callback = function()
				local text = vim.api.nvim_buf_get_lines(self.pbuf, 0, 1, false)[1] or ""
				if text ~= self.query_text then
					self.query_text = text
					self:render_prompt_highlight(text)
					self:run_fetch()
					vim.schedule(function() self:trigger_flag_completion(text, true) end)
				end
			end
		})
	end

	do
		local lbuf_key_opts = _key_opts_of(self.lbuf)
		vim.keymap.set("n", "<Esc>", function() self:close() end, lbuf_key_opts)
		vim.keymap.set("n", "<CR>", function() self:confirm() end, lbuf_key_opts)
	end
end

---@param opts keystone.Picker.opts
---@param callback keystone.Picker.Callback
function M.open(opts, callback)
	assert(opts.finder, "finder missing in opts")
	if _active_picker and not _active_picker.closed then
		_active_picker:close()
	end
	Picker:new(opts, callback)
end

function M.repeat_last()
	if not _last_session then
		vim.notify("No previous picker session", vim.log.levels.INFO)
		return
	end
	local session    = _last_session
	local first_call = true

	local opts       = vim.tbl_extend("force", session.opts, {
		initial_query = session.query,
		finder        = function(query, flags, fetch_opts, callback)
			if first_call then
				first_call = false
				return session.opts.finder(query, flags, fetch_opts, function(items)
					if items and session.cursor_index then
						local target = _sort_by_score(items)[session.cursor_index]
						if target and _item_label(target) == session.cursor_text then
							target.initial = true
						end
					end
					callback(items)
				end)
			end
			return session.opts.finder(query, flags, fetch_opts, callback)
		end,
	})

	Picker:new(opts, session.callback)
end

return M
