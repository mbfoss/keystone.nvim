local Spinner    = require("keystone.utils.Spinner")
local class      = require("keystone.utils.class")
local common     = require("keystone.utils.common")
local fsutils    = require("keystone.utils.fsutils")
local uitools    = require("keystone.utils.uitools")

---@mod keystone.picker
---@brief Floating async picker with fuzzy filtering and optional preview.

local M          = {}

local NS_CURSOR  = vim.api.nvim_create_namespace("keystone_PickerCursor")
local NS_CONTENT = vim.api.nvim_create_namespace("keystone_PickerContent")
local NS_SPINNER = vim.api.nvim_create_namespace("keystone_PickerSpinner")
local NS_PREVIEW = vim.api.nvim_create_namespace("keystone_PickerPreview")


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

---@class keystone.picker.ListItem
---@field text string
---@field score number
---@field data keystone.picker.ItemData

---@alias keystone.Picker.Callback fun(data:keystone.picker.ItemData?)

---@class keystone.Picker.FetcherOpts
---@field list_width number
---@field list_height number

---@class keystone.Picker.QueryHistoryProvider
---@field load fun():string[]
---@field store fun(hist:string[])?

---@alias keystone.Picker.Fetcher fun(query:string,opts:keystone.Picker.FetcherOpts):keystone.Picker.Item[]?,number?
---@alias keystone.Picker.AsyncFetcher fun(query:string,opts:keystone.Picker.FetcherOpts,callback:fun(new_items:keystone.Picker.Item[]?)):fun()?
---@alias keystone.Picker.QueryHighlighter fun(query:string): {start:integer, finish:integer, hl:string}[]

---@class keystone.Picker.AsyncPreviewOpts
---@field viewport_with number?
---@field viewport_height number?


---@alias keystone.Picker.AsyncPreviewData {content:string|string[]|nil,filetype:string?,filepath:string?,lnum:number?,col:number?,error_msg:string?}
---@alias keystone.Picker.AsyncPreviewLoader fun(data:keystone.picker.ItemData, opts:keystone.Picker.AsyncPreviewOpts, callback:fun(preview:keystone.Picker.AsyncPreviewData?)):fun()?

---@class keystone.Picker.opts
---@field prompt string
---@field highlight_query keystone.Picker.QueryHighlighter?
---@field fetch keystone.Picker.Fetcher?
---@field async_fetch keystone.Picker.AsyncFetcher?
---@field enable_preview boolean?
---@field async_preview keystone.Picker.AsyncPreviewLoader?
---@field history_provider keystone.Picker.QueryHistoryProvider?
---@field quickfix_formatter (fun(data:any):vim.quickfix.entry?)?
---@field height_ratio number?
---@field width_ratio number?
---@field list_wrap boolean?
---@field enable_list_sep boolean?

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

local function _key_opts_of(buf)
    return { buffer = buf, nowait = true, silent = true }
end

---@param modifiable boolean
---@param on_delete fun()
local function _create_buffer(modifiable, on_delete)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].modifiable = modifiable
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.bo[buf].undolevels = -1
    vim.bo[buf].modeline = false
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        buffer = buf,
        once = true,
        callback = function()
            on_delete()
        end,
    })
    return buf
end

---@param v number
---@param min number
---@param max number
---@return number
local function _clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

---@param opts {has_preview:boolean,height_ratio:number?,width_ratio:number?}
---@return keystone.Picker.Layout
local function _compute_layout(opts)
    local cols = vim.o.columns
    local lines = vim.o.lines

    local has_preview = opts.has_preview

    -- vertical layout defaults
    local width = math.ceil(cols * _clamp(opts.width_ratio or 0.5, 0.1, 0.9))
    local total_height = math.ceil(lines * _clamp(opts.height_ratio or 0.8, 0.3, 0.95))

    local row = math.floor((lines - total_height) / 2)
    local col = math.floor((cols - width) / 2)

    -- layout:
    -- prompt
    -- gap
    -- list
    -- gap
    -- preview (optional)

    local prompt_height = 1
    local gap = 2

    if not has_preview then
        local list_row = row + prompt_height + gap
        local list_height = total_height - prompt_height - gap

        return {
            prompt_row = row,
            prompt_col = col,
            prompt_width = width,
            prompt_height = prompt_height,

            list_row = list_row,
            list_col = col,
            list_width = width,
            list_height = list_height,

            prev_row = list_row,
            prev_col = col,
            prev_width = 0,
            prev_height = 0,
        }
    end

    local usable_height = total_height - prompt_height - (gap * 2)

    -- split remaining space evenly
    local list_height = math.floor(usable_height / 3)
    local prev_height = usable_height - list_height

    local list_row = row + prompt_height + gap
    local prev_row = list_row + list_height + gap

    return {
        prompt_row = row,
        prompt_col = col,
        prompt_width = width,
        prompt_height = prompt_height,

        list_row = list_row,
        list_col = col,
        list_width = width,
        list_height = list_height,

        prev_row = prev_row,
        prev_col = col,
        prev_width = width,
        prev_height = prev_height,
    }
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
---@param new_score number
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

---@type keystone.Picker.AsyncPreviewLoader
local function _default_preview(data, _, callback)
    local max_preview_size = 10124 * 10124

    local filepath = data.filepath
    if not filepath or filepath == "" then
        callback({})
        return
    end
    if not fsutils.file_exists(filepath) then
        callback({ error_msg = "Invalid file path: " .. tostring(filepath) })
        return
    end
    local cancelled = false
    local cancel_fn
    vim.uv.fs_stat(filepath, vim.schedule_wrap(function(stat_err, stat)
        if cancelled then
            return
        end
        if stat_err or not stat then
            callback({ error_msg = stat_err })
            return
        end
        if stat.size > max_preview_size then
            callback({ error_msg = "Maximum file size exceeded" })
            return
        end
        cancel_fn = fsutils.async_load_text_file(filepath, { timeout = 3000 },
            function(load_err, content)
                callback({
                    content = content,
                    filepath = filepath,
                    lnum = data.lnum,
                    col = data.col,
                    error_msg = load_err,
                })
            end)
    end))
    return function()
        cancelled = true
        if cancel_fn then cancel_fn() end
    end
end

---@class keystone.utils.Picker
---@field new fun(self: keystone.utils.Picker,opts:keystone.Picker.opts,callback:keystone.Picker.Callback) : keystone.utils.Picker
---@field opts keystone.Picker.opts
---@field callback keystone.Picker.Callback
---@field preview_enabled boolean
---@field layout keystone.Picker.Layout
---@field pbuf integer
---@field lbuf integer
---@field vbuf integer?
---@field pwin integer
---@field lwin integer
---@field vwin integer?
---@field spinner keystone.utils.Spinner?
---@field closed boolean
---@field list_items keystone.picker.ListItem[]
---@field async_fetch_context number
---@field async_fetch_cancel fun()?
---@field async_preview_context number
---@field async_preview_cancel fun()?
---@field preview_timer table?
---@field resize_augroup number?
---@field current_query string?
---@field history string[]
---@field history_idx number
local Picker = class()

---@param opts keystone.Picker.opts
---@param callback keystone.Picker.Callback
function Picker:init(opts, callback)
    vim.validate("opts", opts, "table")
    vim.validate("callback", callback, "function")

    self.opts = opts and vim.deepcopy(opts) or {}
    self.callback = callback

    self.preview_enabled = opts.enable_preview

    self.list_items = {} ---@type keystone.picker.ListItem[]

    self.closed = false

    self.async_fetch_context = 0
    self.async_fetch_cancel = nil

    self.async_preview_context = 0
    self.async_preview_cancel = nil

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
        has_preview = false,
        height_ratio = opts.height_ratio,
        width_ratio = opts.width_ratio,
    }

    local title = opts.prompt and (" " .. opts.prompt .. " ") or ""

    if self.opts.enable_list_sep then
        self.list_sep_line = string.rep("─", self.layout.list_width)
    end

    self.pbuf = _create_buffer(true, function()
        self.pbuf = nil
        if not self.closed then
            vim.schedule(function() self:close() end)
        end
    end)
    self.lbuf = _create_buffer(false, function()
        self.pbuf = nil
        if not self.closed then
            vim.schedule(function() self:close() end)
        end
    end)

    local base_cfg = {
        relative = "editor",
        style = "minimal",
        border = "rounded"
    }

    local pwin_augroup
    self.pwin, pwin_augroup = uitools.create_window(self.pbuf, true, vim.tbl_extend("force", base_cfg, {
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

    self.lwin = uitools.create_window(self.lbuf, false, vim.tbl_extend("force", base_cfg, {
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

    local winhl = "NormalFloat:Normal,FloatBorder:Normal"
    for _, w in ipairs({ self.pwin, self.lwin, self.vwin }) do
        if w then
            vim.wo[w].winhighlight = winhl
        end
    end

    vim.wo[self.pwin].wrap = false
    vim.wo[self.lwin].wrap = self.opts.list_wrap ~= false

    ---@type number?
    vim.api.nvim_create_autocmd("WinEnter", {
        group = pwin_augroup,
        callback = function(args)
            local win = vim.api.nvim_get_current_win()
            assert(not self.closed)
            if win ~= self.pwin and win ~= self.lwin and win ~= self.vwin then
                local cfg = vim.api.nvim_win_get_config(win)
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

    vim.keymap.set("i", "<C-r><C-w>", function()
        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes(self.original_cword, true, false, true),
            "i", false
        )
    end, { buffer = self.pbuf, desc = "Page original <cword>" })
end

function Picker:toggle_preview()
    if not self.preview_enabled then return end
    if self.vwin then
        vim.api.nvim_win_close(self.vwin, true)
        self.vwin = nil
        if self.vbuf then
            vim.api.nvim_buf_delete(self.vbuf, { force = true })
            self.vbuf = nil
        end
        self:relayout()
    else
        if not self.vbuf then
            self.vbuf = _create_buffer(false, function()
                self.vbuf = nil
            end)
            local vbuf_key_opts = _key_opts_of(self.vbuf)
            vim.keymap.set("n", "<CR>", function() self:confirm() end, vbuf_key_opts)
            vim.keymap.set("n", "<Esc>", function() self:close() end, vbuf_key_opts)
        end
        self.layout = _compute_layout {
            has_preview = true,
            height_ratio = self.opts.height_ratio,
            width_ratio = self.opts.width_ratio,
        }
        self.vwin = uitools.create_window(self.vbuf, false, {
                relative = "editor",
                style = "minimal",
                border = "rounded",
                row = self.layout.prev_row,
                col = self.layout.prev_col,
                width = self.layout.prev_width,
                height = self.layout.prev_height,
            },
            function()
                self.vwin = nil
                if self.vbuf then
                    vim.api.nvim_buf_delete(self.vbuf, { force = true })
                    self.vbuf = nil
                end
            end)

        vim.wo[self.vwin].wrap = true
        vim.wo[self.vwin].winhighlight = "NormalFloat:Normal,FloatBorder:Normal"

        self:relayout()
        self:update_preview()
    end
end

function Picker:relayout()
    if self.closed then return end

    self.layout = _compute_layout {
        has_preview = self.vwin ~= nil,
        height_ratio = self.opts.height_ratio,
        width_ratio = self.opts.width_ratio,
    }

    if self.opts.enable_list_sep then
        self.list_sep_line = string.rep("─", self.layout.list_width)
    end

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

function Picker:render_prompt_highlight(query)
    if not self.opts.highlight_query then return end
    if not vim.api.nvim_buf_is_valid(self.pbuf) then return end

    vim.api.nvim_buf_clear_namespace(self.pbuf, NS_CONTENT, 0, -1)

    local hls = self.opts.highlight_query(query) or {}

    for _, h in ipairs(hls) do
        vim.api.nvim_buf_set_extmark(self.pbuf, NS_CONTENT, 0, h.start, {
            end_col = h.finish,
            hl_group = h.hl,
        })
    end
end

function Picker:render_ui()
    if not vim.api.nvim_buf_is_valid(self.lbuf) then
        return
    end

    vim.api.nvim_buf_clear_namespace(self.lbuf, NS_CURSOR, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.pbuf, NS_CURSOR, 0, -1)

    local total = #self.list_items
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

    local total = #self.list_items
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

    ---@type keystone.picker.ListItem
    local item = self.list_items[self:get_cursor()]
    if not item then return end

    local preview_width = math.max(0, self.layout.prev_width - 2)   -- -2 for borders
    local preview_height = math.max(0, self.layout.prev_height - 2) -- -2 for borders

    local preview_fn = self.opts.async_preview or _default_preview

    self.async_preview_cancel = preview_fn(
        item.data,
        {
            viewport_with = preview_width,
            viewport_height = preview_height,
        },
        function(preview)
            if not preview or self.closed
                or preview_context ~= self.async_preview_context
                or fetch_context ~= self.async_fetch_context then
                return
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
            if vim.api.nvim_buf_is_valid(self.vbuf) then
                self:cancel_clear_preview_req()
                vim.bo[self.vbuf].modifiable = true
                vim.api.nvim_buf_set_lines(self.vbuf, 0, -1, false, lines)
                vim.bo[self.vbuf].modifiable = false
                if content and preview then
                    local filetype = preview.filetype
                    if not filetype and preview.filepath then
                        filetype = vim.filetype.match({ filename = preview.filepath })
                    end
                    vim.bo[self.vbuf].filetype = filetype or ""
                    if preview.lnum then
                        local lnum = _clamp(preview.lnum, 1, #lines)
                        vim.api.nvim_win_set_cursor(self.vwin, { lnum, 0 })
                        vim.api.nvim_win_call(self.vwin, function()
                            vim.cmd("normal! zz")
                        end)
                        vim.api.nvim_buf_clear_namespace(self.vbuf, NS_PREVIEW, 0, -1)
                        vim.api.nvim_buf_set_extmark(self.vbuf, NS_PREVIEW, lnum - 1, 0, {
                            end_row = lnum,
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
        self.preview_timer = vim.defer_fn(function()
            self.preview_timer = nil
            if self.closed then return end
            vim.bo[self.vbuf].modifiable = true
            vim.api.nvim_buf_set_lines(self.vbuf, 0, -1, false, {})
            vim.bo[self.vbuf].modifiable = false
            vim.api.nvim_buf_clear_namespace(self.vbuf, NS_PREVIEW, 0, -1)
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

    vim.api.nvim_buf_clear_namespace(self.lbuf, NS_CONTENT, 0, -1)
    self:request_clear_preview()
    vim.wo[self.lwin].cursorline = false
    self:render_ui()
end

---@param items keystone.Picker.Item[]
function Picker:add_new_lines(items)
    local prefix = "  "
    local is_fresh = #self.list_items == 0 and
        vim.api.nvim_buf_line_count(self.lbuf) == 1 and
        vim.api.nvim_buf_get_lines(self.lbuf, 0, 1, false)[1] == ""

    for _, item in ipairs(items) do
        -- build label
        local label
        if item.label_chunks then
            local parts = {}
            for _, chunk in ipairs(item.label_chunks) do
                table.insert(parts, chunk[1] or "")
            end
            label = table.concat(parts)
        else
            label = ""
        end
        label = label:gsub("\n", "")
        -- insert in list data
        ---@type keystone.picker.ListItem
        local list_item = {
            text = label,
            score = item.score,
            data = item.data,
        }
        local idx = _find_insert_index(self.list_items, item.score)
        table.insert(self.list_items, idx, list_item)
        -- insert in list buf
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
                        vim.api.nvim_buf_set_extmark(self.lbuf, NS_CONTENT, row, col, {
                            end_col = col + #text,
                            hl_group = hl,
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
            table.insert(vlines, { { self.list_sep_line, "Nontext" } })
        end
        if #vlines > 0 then
            vim.api.nvim_buf_set_extmark(self.lbuf, NS_CONTENT, row, 0, {
                virt_lines = vlines,
                hl_mode = "blend"
            })
        end
    end

    vim.wo[self.lwin].cursorline = #self.list_items > 0
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
        if items then
            self:add_new_lines(items)
            self:move_cursor(initial or 1, true, true)
        end
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
            if complete or self.closed or context ~= self.async_fetch_context then return end
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

            self:add_new_lines(new_items)
            if is_new_query and #self.list_items > 0 then
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
                text     = item.text,
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
    ---@type keystone.picker.ListItem
    local list_item = self.list_items[self:get_cursor()]
    self:close(list_item and list_item.data or nil)
end

---@param selected_data keystone.picker.ItemData?
function Picker:close(selected_data)
    if self.closed then return end
    self.closed = true

    self:stop_spinner()

    self.preview_timer = common.stop_and_close_timer(self.preview_timer)

    if self.async_fetch_cancel then self.async_fetch_cancel() end
    if self.async_preview_cancel then self.async_preview_cancel() end

    for _, w in ipairs({ self.pwin, self.lwin, self.vwin }) do
        if w and vim.api.nvim_win_is_valid(w) then
            vim.api.nvim_win_close(w, true)
        end
    end

    for _, b in ipairs({ self.pbuf, self.lbuf, self.vbuf }) do
        if b and vim.api.nvim_buf_is_valid(b) then
            vim.api.nvim_buf_delete(b, { force = true })
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
    vim.schedule(function()
        self.callback(selected_data)
    end)
end

function Picker:setup_input()
    do
        local pbuf_key_opts = _key_opts_of(self.pbuf)
        vim.keymap.set({ "i", "n" }, "<CR>", function() self:confirm() end, pbuf_key_opts)

        vim.keymap.set("n", "<Esc>", function() self:close() end, pbuf_key_opts)
        vim.keymap.set("i", "<C-c>", function() self:close() end, pbuf_key_opts)

        vim.keymap.set("i", "<Down>", function() self:move_cursor(self:get_cursor() + 1) end, pbuf_key_opts)
        vim.keymap.set("i", "<C-n>", function() self:move_cursor(self:get_cursor() + 1) end, pbuf_key_opts)

        vim.keymap.set("i", "<Up>", function() self:move_cursor(self:get_cursor() - 1) end, pbuf_key_opts)
        vim.keymap.set("i", "<C-p>", function() self:move_cursor(self:get_cursor() - 1) end, pbuf_key_opts)

        vim.keymap.set("i", "<C-d>", function()
            local cur = self:get_cursor()
            local step = math.floor(self.layout.list_height / 2)
            self:move_cursor(cur + step, false, true)
        end, pbuf_key_opts)

        vim.keymap.set("i", "<C-u>", function()
            local cur = self:get_cursor()
            local step = math.floor(self.layout.list_height / 2)
            self:move_cursor(cur - step, false, true)
        end, pbuf_key_opts)

        vim.keymap.set("i", "<C-j>", function() self:history_next() end, pbuf_key_opts)
        vim.keymap.set("i", "<C-k>", function() self:history_prev() end, pbuf_key_opts)

        vim.keymap.set("i", "<C-q>", function() self:send_to_qf() end, pbuf_key_opts)

        vim.keymap.set({ "n", "i" }, "<Tab>", function() self:toggle_preview() end, pbuf_key_opts)

        vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
            buffer = self.pbuf,
            callback = function()
                local query = vim.api.nvim_buf_get_lines(self.pbuf, 0, 1, false)[1] or ""
                self:render_prompt_highlight(query)
                self:run_fetch(query)
            end
        })
    end

    do
        local lbuf_key_opts = _key_opts_of(self.lbuf)
        vim.keymap.set("n", "<Esc>", function() self:close() end, lbuf_key_opts)
    end
end

function Picker:open()
    assert(not self._open_called)
    self._open_called = true

    self:setup_input()
    self:run_fetch("")

    vim.api.nvim_set_current_win(self.pwin)

    vim.schedule(function()
        vim.cmd("startinsert!")
    end)
end

---@param opts keystone.Picker.opts
---@param callback keystone.Picker.Callback
function M.open(opts, callback)
    assert(opts.fetch or opts.async_fetch)

    local picker = Picker:new(opts, callback)
    picker:open()
end

return M
