local Spinner    = require("keystone.utils.Spinner")
local class      = require("keystone.utils.class")
local utils      = require("keystone.utils.utils")

---@mod keystone.picker
---@brief Floating async picker with fuzzy filtering and optional preview.

local M          = {}

local NS_CURSOR  = vim.api.nvim_create_namespace("LoopPlugin_PickerCursor")
local NS_VIRT    = vim.api.nvim_create_namespace("LoopPlugin_PickerVirtText")
local NS_SPINNER = vim.api.nvim_create_namespace("LoopPlugin_PickerSpinner")
local NS_PREVIEW = vim.api.nvim_create_namespace("LoopPlugin_PickerPreview")

---@class keystone.Picker.Item
---@field label string?
---@field label_chunks {[1]:string,[2]:string?}[]?
---@field virt_lines? {[1]:string,[2]:string?}[][]
---@field score number?
---@field data any

---@alias keystone.Picker.Callback fun(data:any|nil)

---@class keystone.Picker.FetcherOpts
---@field list_width number
---@field list_height number

---@class keystone.Picker.AsyncPreviewOpts
---@field preview_width number
---@field preview_height number
---@field antiflicker_delay number

---@class keystone.Picker.QueryHistoryProvider
---@field load fun():string[]
---@field store fun(hist:string[])?

---@alias keystone.Picker.Fetcher fun(query:string,opts:keystone.Picker.FetcherOpts):keystone.Picker.Item[]?,number?
---@alias keystone.Picker.AsyncFetcher fun(query:string,opts:keystone.Picker.FetcherOpts,callback:fun(new_items:keystone.Picker.Item[]?)):fun()?

---@alias keystone.Picker.AsyncPreviewInfo {filetype:string?,filepath:string?,lnum:number?,col:number?,error_msg:string?}
---@alias keystone.Picker.AsyncPreviewLoader fun(data:any,opts:keystone.Picker.AsyncPreviewOpts,callback:fun(preview:string?,info:keystone.Picker.AsyncPreviewInfo?)):fun()?

---@class keystone.Picker.opts
---@field prompt string
---@field fetch keystone.Picker.Fetcher?
---@field async_fetch keystone.Picker.AsyncFetcher?
---@field async_preview keystone.Picker.AsyncPreviewLoader?
---@field history_provider keystone.Picker.QueryHistoryProvider?
---@field height_ratio number?
---@field width_ratio number?
---@field list_width number?
---@field list_wrap boolean?

---@class keystone.Picker.Layout
---@field prompt_row number
---@field prompt_col number
---@field prompt_width number
---@field prompt_height number
---@field list_row number
---@field list_col number
---@field list_width number
---@field list_height number
---@field prev_row number
---@field prev_col number
---@field prev_width number
---@field prev_height number

---@param v number
---@param min number
---@param max number
---@return number
local function _clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

---@param opts {has_preview:boolean,height_ratio:number?,width_ratio:number?,list_width:number?}
---@return keystone.Picker.Layout
local function _compute_layout(opts)
    local cols = vim.o.columns
    local lines = vim.o.lines

    local has_preview = opts.has_preview
    local spacing = has_preview and 2 or 0
    local half_spacing = math.floor(spacing / 2)

    local list_width
    local prev_width
    if has_preview then
        local width = math.ceil(cols * _clamp(opts.width_ratio or 0.8, 0.1, 0.8))
        local half_width = math.floor(width / 2)
        if opts.list_width then
            list_width = _clamp(opts.list_width + 3, math.ceil(half_width / 2), half_width)
        else
            list_width = half_width
        end
        list_width = list_width - half_spacing
        prev_width = _clamp(width - list_width - half_spacing, 1, width)
    else
        local max_width = math.ceil(cols * (opts.width_ratio or 0.8))
        if opts.list_width then
            local min_width = math.floor(cols * 0.3)
            list_width = _clamp(opts.list_width + 3, min_width, max_width)
        else
            list_width = max_width
        end
        prev_width = 0
    end

    local total_height = math.ceil(lines * _clamp(opts.height_ratio or .7, 0.3, 0.8))
    local list_height = _clamp(total_height - 3, 1, lines)

    local row = math.floor((lines - total_height - 1) / 2)
    local col = math.floor((cols - (list_width + prev_width + spacing)) / 2)

    return {
        prompt_row = row,
        prompt_col = col,
        prompt_width = list_width + prev_width + spacing,
        prompt_height = 1,

        list_row = row + 3,
        list_col = col,
        list_width = list_width,
        list_height = list_height,

        prev_row = row + 3,
        prev_col = col + list_width + spacing,
        prev_width = prev_width,
        prev_height = list_height
    }
end

---@param msg string
---@param width number
---@param height number
---@return string[]
local function _center_for_previwer(msg, width, height)
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
local function _find_insert_index(items, new_score)
    if not new_score then
        return #items + 1
    end
    local low, high = 1, #items
    while low <= high do
        local mid = math.floor((low + high) / 2)
        if (items[mid].score or 0) < (new_score or 0) then
            high = mid - 1
        else
            low = mid + 1
        end
    end
    return low
end

---@class keystone.utils.Picker
---@field new fun(self: keystone.utils.Picker,opts:keystone.Picker.opts,callback:keystone.Picker.Callback) : keystone.utils.Picker
---@field opts keystone.Picker.opts
---@field callback keystone.Picker.Callback
---@field has_preview boolean
---@field layout keystone.Picker.Layout
---@field pbuf integer
---@field lbuf integer
---@field vbuf integer|nil
---@field pwin integer
---@field lwin integer
---@field vwin integer|nil
---@field spinner keystone.utils.Spinner|nil
---@field closed boolean
---@field items_data any[]
---@field async_fetch_context number
---@field async_fetch_cancel fun()|nil
---@field async_preview_context number
---@field async_preview_cancel fun()|nil
---@field preview_timer table|nil
---@field resize_augroup number?
---@field current_query string?
---@field history string[]
---@field history_idx number
local Picker = class()

---@param opts keystone.Picker.opts
---@param callback keystone.Picker.Callback
function Picker:init(opts, callback)
    self.opts = opts
    self.callback = callback

    self.has_preview = type(opts.async_preview) == "function"

    self.items_data = {}

    self.closed = false

    self.async_fetch_context = 0
    self.async_fetch_cancel = nil

    self.async_preview_context = 0
    self.async_preview_cancel = nil

    self.antiflicker_delay = 200
    self.spinner = nil

    self.history = {}
    self.history_idx = 0

    if self.opts.history_provider then
        self.history = self.opts.history_provider.load() or {}
        self.history_idx = #self.history + 1
    end

    local cword_ok, cword = pcall(vim.fn.expand, "<cword>")
    self.original_cword = tostring(cword_ok and (type(cword) == "table" and cword[1] or cword) or "")

    self:setup_ui()
end

---@return nil
function Picker:setup_ui()
    local opts = self.opts

    self.layout = _compute_layout {
        has_preview = self.has_preview,
        height_ratio = opts.height_ratio,
        width_ratio = opts.width_ratio,
        list_width = opts.list_width
    }

    local title = opts.prompt and (" " .. opts.prompt .. " ") or ""

    self.pbuf = vim.api.nvim_create_buf(false, true)
    self.lbuf = vim.api.nvim_create_buf(false, true)
    self.vbuf = self.has_preview and vim.api.nvim_create_buf(false, true) or nil

    vim.bo[self.lbuf].modifiable = false
    if self.vbuf then vim.bo[self.vbuf].modifiable = false end

    for _, b in ipairs({ self.pbuf, self.lbuf, self.vbuf }) do
        if b then
            vim.bo[b].buftype = "nofile"
            vim.bo[b].bufhidden = "wipe"
            vim.bo[b].swapfile = false
            vim.bo[b].undolevels = -1
            vim.bo[b].modeline = false
            vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
                buffer = b,
                once = true,
                callback = function(ev)
                    if (b == self.pbuf) then self.pbuf = -1 end
                    if (b == self.lbuf) then self.lbuf = -1 end
                    if (b == self.vbuf) then self.vbuf = -1 end
                    vim.schedule(function() self:close() end)
                end,
            })
        end
    end

    local base_cfg = {
        relative = "editor",
        style = "minimal",
        border = "rounded"
    }

    self.pwin = vim.api.nvim_open_win(self.pbuf, true, vim.tbl_extend("force", base_cfg, {
        row = self.layout.prompt_row,
        col = self.layout.prompt_col,
        width = self.layout.prompt_width,
        height = 1,
        title = title,
        title_pos = "center"
    }))

    self.lwin = vim.api.nvim_open_win(self.lbuf, false, vim.tbl_extend("force", base_cfg, {
        row = self.layout.list_row,
        col = self.layout.list_col,
        width = self.layout.list_width,
        height = self.layout.list_height
    }))

    if self.vbuf then
        self.vwin = vim.api.nvim_open_win(self.vbuf, false, vim.tbl_extend("force", base_cfg, {
            row = self.layout.prev_row,
            col = self.layout.prev_col,
            width = self.layout.prev_width,
            height = self.layout.prev_height
        }))
        vim.wo[self.vwin].wrap = true
    end

    local winhl = "NormalFloat:Normal,FloatBorder:LoopTransparentBorder"
    for _, w in ipairs({ self.pwin, self.lwin, self.vwin }) do
        if w then
            vim.wo[w].winhighlight = winhl
        end
    end

    vim.wo[self.pwin].wrap = false
    vim.wo[self.lwin].wrap = self.opts.list_wrap ~= false

    ---@type number?
    local focus_augroup = vim.api.nvim_create_augroup("LoopPlugin_PickerFocus_" .. self.pbuf, { clear = true })
    vim.api.nvim_create_autocmd("WinEnter", {
        group = focus_augroup,
        callback = function(args)
            local win = vim.api.nvim_get_current_win()
            if win ~= self.pwin and win ~= self.lwin and win ~= self.vwin then
                local cfg = vim.api.nvim_win_get_config(win)
                if cfg.relative == "" then -- skip popups
                    vim.schedule(function()
                        if focus_augroup then
                            vim.api.nvim_del_augroup_by_id(focus_augroup)
                            focus_augroup = nil
                        end
                        self:close(nil)
                    end)
                end
            end
        end
    })

    assert(not self.resize_augroup)
    self.resize_augroup = vim.api.nvim_create_augroup("LoopPlugin_PickerResize_" .. self.pbuf, { clear = true })
    vim.api.nvim_create_autocmd("VimResized", {
        group = self.resize_augroup,
        callback = function()
            vim.schedule(function()
                if not self.closed then
                    self:on_resize()
                elseif self.resize_augroup then
                    vim.api.nvim_del_augroup_by_id(self.resize_augroup)
                    self.resize_augroup = nil
                end
            end)
        end
    })
    assert(self.pbuf > 0)
    vim.keymap.set("i", "<C-r><C-w>", function()
        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes(self.original_cword, true, false, true),
            "i", false
        )
    end, { buffer = self.pbuf, desc = "Page original <cword>" })
end

function Picker:on_resize()
    if self.closed then return end

    self.layout = _compute_layout {
        has_preview = self.has_preview,
        height_ratio = self.opts.height_ratio,
        width_ratio = self.opts.width_ratio,
        list_width = self.opts.list_width
    }

    local base = {
        relative = "editor",
    }

    if self.pwin and vim.api.nvim_win_is_valid(self.pwin) then
        vim.api.nvim_win_set_config(self.pwin, vim.tbl_extend("force", base, {
            row = self.layout.prompt_row,
            col = self.layout.prompt_col,
            width = self.layout.prompt_width,
            height = 1,
        }))
    end

    if self.lwin and vim.api.nvim_win_is_valid(self.lwin) then
        vim.api.nvim_win_set_config(self.lwin, vim.tbl_extend("force", base, {
            row = self.layout.list_row,
            col = self.layout.list_col,
            width = self.layout.list_width,
            height = self.layout.list_height,
        }))
    end

    if self.vwin and vim.api.nvim_win_is_valid(self.vwin) then
        vim.api.nvim_win_set_config(self.vwin, vim.tbl_extend("force", base, {
            row = self.layout.prev_row,
            col = self.layout.prev_col,
            width = self.layout.prev_width,
            height = self.layout.prev_height,
        }))
    end
end

---@return nil
function Picker:render_ui()
    if not vim.api.nvim_buf_is_valid(self.lbuf) then
        return
    end

    vim.api.nvim_buf_clear_namespace(self.lbuf, NS_CURSOR, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.pbuf, NS_CURSOR, 0, -1)

    local total = #self.items_data
    if total == 0 then
        return
    end

    local cur = self:get_cursor()

    if total > 0 then
        vim.api.nvim_buf_set_extmark(self.lbuf, NS_CURSOR, cur - 1, 0, {
            virt_text = { { "> ", "Special" } },
            virt_text_pos = "overlay",
            priority = 200,
        })
    end

    if total > 0 and vim.api.nvim_buf_is_valid(self.pbuf) then
        local text = string.format("%d/%d", cur, total)

        vim.api.nvim_buf_set_extmark(self.pbuf, NS_CURSOR, 0, 0, {
            virt_text = { { text, "Comment" } },
            virt_text_pos = "right_align",
            hl_mode = "blend",
            priority = 1,
        })
    end
end

---@return integer
function Picker:get_cursor()
    return vim.api.nvim_win_get_cursor(self.lwin)[1]
end

---@param row integer
---@param force boolean?
---@param clamp boolean?
function Picker:move_cursor(row, force, clamp)
    if not force then
        if row == self:get_cursor() then return end
    end

    local total = #self.items_data
    if total == 0 then return end

    if clamp then
        row = _clamp(row, 1, total)
    else
        if row > total then row = 1 end
        if row < 1 then row = total end
    end

    vim.api.nvim_win_set_cursor(self.lwin, { row, 0 })

    self:render_ui()
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

    local item = self.items_data[self:get_cursor()]
    local data = item and item.data

    if not data then return end

    local preview_width = math.max(0, self.layout.prev_width - 2)   -- -2 for borders
    local preview_height = math.max(0, self.layout.prev_height - 2) -- -2 for borders

    self.async_preview_cancel = self.opts.async_preview(
        data,
        {
            preview_width = preview_width,
            preview_height = preview_height,
            antiflicker_delay = self.antiflicker_delay,
        },
        function(preview, info)
            if self.closed or preview_context ~= self.async_preview_context or fetch_context ~= self.async_fetch_context then return end
            local lines
            if preview then
                lines = vim.split(preview, "\n")
            elseif info and info.error_msg then
                lines = _center_for_previwer(info.error_msg, preview_width, preview_height)
            end
            lines = lines or {}
            if vim.api.nvim_buf_is_valid(self.vbuf) then
                self:cancel_clear_preview_req()
                vim.bo[self.vbuf].modifiable = true
                vim.api.nvim_buf_set_lines(self.vbuf, 0, -1, false, lines)
                vim.bo[self.vbuf].modifiable = false
                if preview and info then
                    local filetype = info.filetype
                    if not filetype and info.filepath then
                        filetype = vim.filetype.match({ filename = info.filepath })
                    end
                    vim.bo[self.vbuf].filetype = filetype or ""
                    if info.lnum then
                        local lnum = _clamp(info.lnum, 1, #lines)
                        vim.api.nvim_win_set_cursor(self.vwin, { lnum, 0 })
                        vim.api.nvim_win_call(self.vwin, function()
                            vim.cmd("normal! zz") -- center the target line
                        end)
                        vim.api.nvim_buf_clear_namespace(self.vbuf, NS_PREVIEW, 0, -1)
                        vim.api.nvim_buf_set_extmark(self.vbuf, NS_PREVIEW, lnum - 1, 0, {
                            end_row = lnum, -- makes it "multiline" → enables hl_eol
                            hl_group = "Visual",
                            hl_eol = true,
                            hl_mode = "blend",
                        })
                    else
                        vim.api.nvim_win_set_cursor(self.vwin, { 1, 0 })
                    end
                else
                    vim.bo[self.vbuf].filetype = ""
                    vim.api.nvim_win_set_cursor(self.vwin, { 1, 0 })
                end
            end
        end
    )
    assert(type(self.async_preview_cancel) == "function")
end

function Picker:start_spinner()
    if self.spinner then return end

    self.spinner = Spinner:new {
        interval = 80,
        on_update = function(frame)
            if not vim.api.nvim_buf_is_valid(self.pbuf) then return end

            vim.api.nvim_buf_clear_namespace(self.pbuf, NS_SPINNER, 0, -1)

            vim.api.nvim_buf_set_extmark(self.pbuf, NS_SPINNER, 0, 0, {
                virt_text = { { frame .. " ", "Comment" } },
                virt_text_pos = "right_align"
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

    if vim.api.nvim_buf_is_valid(self.pbuf) then
        vim.api.nvim_buf_clear_namespace(self.pbuf, NS_SPINNER, 0, -1)
    end
end

function Picker:request_clear_preview()
    if self.vbuf and self.vbuf > 0 and not self.preview_timer then
        ---@diagnostic disable-next-line: undefined-field
        self.preview_timer = vim.defer_fn(function()
            self.preview_timer = nil
            if self.closed then return end
            vim.bo[self.vbuf].modifiable = true
            vim.api.nvim_buf_set_lines(self.vbuf, 0, -1, false, {})
            vim.bo[self.vbuf].modifiable = false
            vim.api.nvim_buf_clear_namespace(self.vbuf, NS_PREVIEW, 0, -1)
        end, self.antiflicker_delay)
    end
end

function Picker:cancel_clear_preview_req()
    self.preview_timer = utils.stop_and_close_timer(self.preview_timer)
end

function Picker:clear_list()
    self.items_data = {}

    vim.bo[self.lbuf].modifiable = true
    vim.api.nvim_buf_set_lines(self.lbuf, 0, -1, false, {})
    vim.bo[self.lbuf].modifiable = false

    vim.api.nvim_buf_clear_namespace(self.lbuf, NS_VIRT, 0, -1)
    self:request_clear_preview()
    vim.wo[self.lwin].cursorline = false
    self:render_ui()
end

function Picker:add_new_lines(items, query)
    local prefix = "  "
    local is_fresh = #self.items_data == 0 and
        vim.api.nvim_buf_line_count(self.lbuf) == 1 and
        vim.api.nvim_buf_get_lines(self.lbuf, 0, 1, false)[1] == ""

    for _, item in ipairs(items) do
        local idx = _find_insert_index(self.items_data, item.score)
        table.insert(self.items_data, idx, item)
        local label = item.label
        if not label and item.label_chunks then
            local parts = {}
            for _, chunk in ipairs(item.label_chunks) do
                table.insert(parts, chunk[1] or "")
            end
            label = table.concat(parts)
        end
        label = (label or ""):gsub("\n", "")
        local line_text = prefix .. label
        local row = idx - 1
        vim.bo[self.lbuf].modifiable = true
        if is_fresh and idx == 1 then
            vim.api.nvim_buf_set_lines(self.lbuf, 0, 1, false, { line_text })
            is_fresh = false -- No longer fresh after first insertion
        else
            vim.api.nvim_buf_set_lines(self.lbuf, row, row, false, { line_text })
        end
        vim.bo[self.lbuf].modifiable = false
        if item.label_chunks then
            local col = #prefix
            for _, chunk in ipairs(item.label_chunks) do
                local text, hl = chunk[1], chunk[2]
                if text and #text > 0 then
                    if hl then
                        vim.api.nvim_buf_set_extmark(self.lbuf, NS_VIRT, row, col, {
                            end_col = col + #text,
                            hl_group = hl,
                        })
                    end
                    col = col + #text
                end
            end
        end
        if item.virt_lines and #item.virt_lines > 0 then
            local vlines = {}
            for _, line in ipairs(item.virt_lines) do
                local vl = { { prefix } }
                vim.list_extend(vl, line)
                table.insert(vlines, vl)
            end
            vim.api.nvim_buf_set_extmark(self.lbuf, NS_VIRT, row, 0, {
                virt_lines = vlines,
                hl_mode = "blend"
            })
        end
    end

    vim.wo[self.lwin].cursorline = #self.items_data > 0
end

---@param query string
function Picker:run_fetch(query)
    local is_new_query = (query ~= self.current_query)
    self.current_query = query

    if self.async_fetch_cancel then
        self.async_fetch_cancel()
        self.async_fetch_cancel = nil
    end

    self:stop_spinner()
    self:request_clear_preview()

    local fetch_opts = {
        list_width = math.max(1, self.layout.list_width - 2), -- -2 for borders
        list_height = math.max(1, self.layout.list_height - 2),
    }

    if self.opts.fetch then
        self:clear_list()
        local items, initial = self.opts.fetch(query, fetch_opts)
        self:add_new_lines(items, query)
        self:move_cursor(initial or 1, true, true)
        return
    end

    self.async_fetch_context = self.async_fetch_context + 1
    local context = self.async_fetch_context

    local waiting_first = true
    local complete = false

    self.async_fetch_cancel = self.opts.async_fetch(
        query,
        fetch_opts,
        function(new_items)
            if self.closed or context ~= self.async_fetch_context then return end
            local saved_cursor = 1
            if not is_new_query and not waiting_first then
                saved_cursor = self:get_cursor()
            end

            if waiting_first then
                waiting_first = false
                self:clear_list()
            end

            if new_items == nil then
                complete = true
                self:stop_spinner()
                return
            end

            self:add_new_lines(new_items, query)
            if is_new_query and #self.items_data > 0 then
                self:move_cursor(1, true, true)
                is_new_query = false -- Reset so subsequent async chunks don't snap to top
            else
                self:move_cursor(saved_cursor, true, true)
            end
        end
    )
    assert(type(self.async_fetch_cancel) == "function")

    if not complete then
        self:start_spinner()
    end
end

function Picker:history_prev()
    if not self.opts.history_provider or #self.history == 0 then return end

    local new_idx = math.max(1, self.history_idx - 1)
    if new_idx ~= self.history_idx then
        self.history_idx = new_idx
        self:set_prompt_text(self.history[self.history_idx])
    end
end

function Picker:history_next()
    if not self.opts.history_provider then return end

    local new_idx = self.history_idx + 1
    if new_idx <= #self.history then
        self.history_idx = new_idx
        self:set_prompt_text(self.history[self.history_idx])
    elseif new_idx == #self.history + 1 then
        self.history_idx = new_idx
        self:set_prompt_text("")
    end
end
function Picker:set_prompt_text(text)
    vim.api.nvim_buf_set_lines(self.pbuf, 0, -1, false, { text })
    vim.api.nvim_win_set_cursor(self.pwin, { 1, #text })
end

function Picker:send_to_qf()
    if #self.items_data == 0 then return end
    local qf_entries = {}
    for _, item in ipairs(self.items_data) do
        local d = item.data
        if d then
            local label = item.label
            if not label and item.label_chunks then
                local parts = {}
                for _, chunk in ipairs(item.label_chunks) do
                    table.insert(parts, chunk[1] or "")
                end
                label = table.concat(parts)
            end
            label = (label or ""):gsub("\n", "")
            table.insert(qf_entries, {
                filename = d.filepath or d.filename or d.path,
                lnum     = d.lnum or 1,
                col      = d.col or 1,
                text     = label,
            })
        end
    end
    if #qf_entries > 0 then
        self:close(nil)
        vim.fn.setqflist(qf_entries, "r")
        vim.cmd("copen")
        print(string.format("Sent %d items to Quickfix", #qf_entries))
    end
end

---@param result any|nil
function Picker:close(result)
    if self.closed then return end
    self.closed = true

    self:stop_spinner()

    self.preview_timer = utils.stop_and_close_timer(self.preview_timer)

    if self.async_fetch_cancel then self.async_fetch_cancel() end
    if self.async_preview_cancel then self.async_preview_cancel() end

    if self.resize_augroup then
        vim.api.nvim_del_augroup_by_id(self.resize_augroup)
        self.resize_augroup = nil
    end

    for _, w in ipairs({ self.pwin, self.lwin, self.vwin }) do
        if w and vim.api.nvim_win_is_valid(w) then
            vim.api.nvim_win_close(w, true)
        end
    end
    if self.opts.history_provider then
        if self.current_query and self.current_query ~= "" and self.current_query ~= self.history[#self.history] then
            table.insert(self.history, self.current_query)
            if self.opts.history_provider.store then
                self.opts.history_provider.store(self.history)
            end
        end
    end

    vim.cmd("stopinsert!")
    if result ~= nil then
        vim.schedule(function()
            self.callback(result)
        end)
    end
end

function Picker:setup_input()
    local key_opts = { buffer = self.pbuf, nowait = true, silent = true }

    vim.keymap.set("i", "<CR>", function()
        local item = self.items_data[self:get_cursor()]
        self:close(item and item.data)
    end, key_opts)

    vim.keymap.set("n", "<Esc>", function() self:close(nil) end, key_opts)
    vim.keymap.set("i", "<C-c>", function() self:close(nil) end, key_opts)

    vim.keymap.set("i", "<Down>", function()
        self:move_cursor(self:get_cursor() + 1)
    end, key_opts)

    vim.keymap.set("i", "<C-n>", function()
        self:move_cursor(self:get_cursor() + 1)
    end, key_opts)

    vim.keymap.set("i", "<Up>", function()
        self:move_cursor(self:get_cursor() - 1)
    end, key_opts)

    vim.keymap.set("i", "<C-p>", function()
        self:move_cursor(self:get_cursor() - 1)
    end, key_opts)

    vim.keymap.set("i", "<C-d>", function()
        local cur = self:get_cursor()
        local step = math.floor(self.layout.list_height / 2)
        self:move_cursor(cur + step, false, true)
    end, key_opts)

    vim.keymap.set("i", "<C-u>", function()
        local cur = self:get_cursor()
        local step = math.floor(self.layout.list_height / 2)
        self:move_cursor(cur - step, false, true)
    end, key_opts)

    vim.keymap.set("i", "<C-j>", function()
        self:history_next()
    end, key_opts)

    vim.keymap.set("i", "<C-k>", function()
        self:history_prev()
    end, key_opts)

    vim.keymap.set("i", "<C-q>", function()
        self:send_to_qf()
    end, key_opts)

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = self.pbuf,
        callback = function()
            local query = vim.api.nvim_buf_get_lines(self.pbuf, 0, 1, false)[1] or ""
            self:run_fetch(query)
        end
    })
end

function Picker:start()
    self:setup_input()
    self:run_fetch("")

    vim.api.nvim_set_current_win(self.pwin)

    vim.schedule(function()
        vim.cmd("startinsert!")
    end)
end

---@param opts keystone.Picker.opts
---@param callback keystone.Picker.Callback
function M.select(opts, callback)
    assert(opts.fetch or opts.async_fetch)

    local picker = Picker:new(opts, callback)
    picker:start()
end

return M
