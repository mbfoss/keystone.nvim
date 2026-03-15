local Spinner    = require("loop.tools.Spinner")
local class      = require("loop.tools.class")
local fntools    = require("loop.tools.fntools")

---@mod loop.picker
---@brief Floating async picker with fuzzy filtering and optional preview.

local M          = {}

--------------------------------------------------------------------------------
-- Namespaces
--------------------------------------------------------------------------------

local NS_CURSOR  = vim.api.nvim_create_namespace("KeystonePlugin_PickerCursor")
local NS_VIRT    = vim.api.nvim_create_namespace("KeystonePlugin_PickerVirtText")
local NS_SPINNER = vim.api.nvim_create_namespace("KeystonePlugin_PickerSpinner")
local NS_PREVIEW = vim.api.nvim_create_namespace("KeystonePlugin_PickerPreview")

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

---@class loop.Picker.Item
---@field label string?
---@field label_chunks {[1]:string,[2]:string?}[]?
---@field virt_lines? {[1]:string,[2]:string?}[][]
---@field data any

---@alias loop.Picker.Callback fun(data:any|nil)

---@class loop.Picker.FetcherOpts
---@field list_width number
---@field list_height number

---@class loop.Picker.AsyncPreviewOpts
---@field preview_width number
---@field preview_height number
---@field antiflicker_delay number

---@class loop.Picker.QueryHistoryProvider
---@field load fun():string[]
---@field store fun(hist:string[])?

---@alias loop.Picker.Fetcher fun(query:string,opts:loop.Picker.FetcherOpts):loop.Picker.Item[]?,number?
---@alias loop.Picker.AsyncFetcher fun(query:string,opts:loop.Picker.FetcherOpts,callback:fun(new_items:loop.Picker.Item[]?)):fun()?

---@alias loop.Picker.AsyncPreviewInfo {filetype:string?,filepath:string?,lnum:number?,col:number?}
---@alias loop.Picker.AsyncPreviewLoader fun(data:any,opts:loop.Picker.AsyncPreviewOpts,callback:fun(preview:string?,info:loop.Picker.AsyncPreviewInfo?)):fun()?

---@class loop.Picker.opts
---@field prompt string
---@field fetch loop.Picker.Fetcher?
---@field async_fetch loop.Picker.AsyncFetcher?
---@field async_preview loop.Picker.AsyncPreviewLoader?
---@field history_provider loop.Picker.QueryHistoryProvider?
---@field height_ratio number?
---@field width_ratio number?
---@field list_width number?
---@field list_wrap boolean?

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

---@class loop.Picker.Layout
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

--------------------------------------------------------------------------------
-- Utility
------------------------------------------------layout_height--------------------------------

---@param v number
---@param min number
---@param max number
---@return number
local function _clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

--------------------------------------------------------------------------------
-- Layout computation
--------------------------------------------------------------------------------

---@param opts {has_preview:boolean,height_ratio:number?,width_ratio:number?,list_width:number?}
---@return loop.Picker.Layout
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
        local max_with = math.ceil(cols * (opts.width_ratio or 0.8))
        if opts.list_width then
            list_width = _clamp(opts.list_width + 3, 30, max_with)
        else
            list_width = max_with
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

--------------------------------------------------------------------------------
-- Picker Class
--------------------------------------------------------------------------------

---@class loop.tools.Picker
---@field new fun(self: loop.tools.Picker,opts:loop.Picker.opts,callback:loop.Picker.Callback) : loop.tools.Picker
---@field opts loop.Picker.opts
---@field callback loop.Picker.Callback
---@field has_preview boolean
---@field layout loop.Picker.Layout
---@field pbuf integer
---@field lbuf integer
---@field vbuf integer|nil
---@field pwin integer
---@field lwin integer
---@field vwin integer|nil
---@field spinner loop.tools.Spinner|nil
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

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

---@param opts loop.Picker.opts
---@param callback loop.Picker.Callback
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
        -- Start index at length + 1 (the "empty/new" entry)
        self.history_idx = #self.history + 1
    end

    self:setup_ui()
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

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

    local winhl = "NormalFloat:Normal,FloatBorder:KeystoneTransparentBorder"
    for _, w in ipairs({ self.pwin, self.lwin, self.vwin }) do
        if w then
            vim.wo[w].winhighlight = winhl
        end
    end

    vim.wo[self.pwin].wrap = false
    vim.wo[self.lwin].wrap = self.opts.list_wrap ~= false

    ---@type number?
    local focus_augroup = vim.api.nvim_create_augroup("KeystonePlugin_PickerFocus_" .. self.pbuf, { clear = true })
    vim.api.nvim_create_autocmd("WinEnter", {
        group = focus_augroup,
        callback = function(args)
            local win = vim.api.nvim_get_current_win()
            if win ~= self.pwin and win ~= self.lwin and win ~= self.vwin then
                vim.schedule(function()
                    if focus_augroup then
                        vim.api.nvim_del_augroup_by_id(focus_augroup)
                        focus_augroup = nil
                    end
                    self:close(nil)
                end)
            end
        end
    })

    assert(not self.resize_augroup)
    self.resize_augroup = vim.api.nvim_create_augroup("KeystonePlugin_PickerResize_" .. self.pbuf, { clear = true })
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

--------------------------------------------------------------------------------
-- UI Rendering
--------------------------------------------------------------------------------

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

    ------------------------------------------------
    -- Cursor marker
    ------------------------------------------------

    if total > 0 then
        vim.api.nvim_buf_set_extmark(self.lbuf, NS_CURSOR, cur - 1, 0, {
            virt_text = { { "> ", "Special" } },
            virt_text_pos = "overlay",
            priority = 200,
        })
    end

    ------------------------------------------------
    -- Position hint
    ------------------------------------------------

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

--------------------------------------------------------------------------------
-- Cursor
--------------------------------------------------------------------------------

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

--------------------------------------------------------------------------------
-- Preview
--------------------------------------------------------------------------------

---@return nil
function Picker:update_preview()
    if self.closed then return end
    if not self.vbuf then return end

    if self.async_preview_cancel then
        self.async_preview_cancel()
        self.async_preview_cancel = nil
    end

    self:request_clear_preview()
    local data = self.items_data[self:get_cursor()]

    self.async_preview_context = self.async_preview_context + 1
    local context = self.async_preview_context

    self.async_preview_cancel = self.opts.async_preview(
        data,
        {
            preview_width = self.layout.prev_width,
            preview_height = self.layout.prev_height,
            antiflicker_delay = self.antiflicker_delay,
        },
        function(preview, info)
            if self.closed or context ~= self.async_preview_context then return end
            self:cancel_clear_preview_req()
            local lines = preview and vim.split(preview, "\n") or {}
            if vim.api.nvim_buf_is_valid(self.vbuf) then
                vim.api.nvim_buf_set_lines(self.vbuf, 0, -1, false, lines)
                if info then
                    -- Set the filetype for syntax highlighting
                    if info.filetype then
                        vim.bo[self.vbuf].filetype = info.filetype
                    elseif info.filepath then
                        local ft = vim.filetype.match({ filename = info.filepath })
                        if ft then
                            vim.bo[self.vbuf].filetype = ft
                        end
                    end
                    if info.lnum then
                        local lnum = _clamp(info.lnum, 1, #lines)
                        vim.api.nvim_win_set_cursor(self.vwin, { lnum, 0 })
                        vim.api.nvim_win_call(self.vwin, function()
                            vim.cmd("normal! zz") -- center the target line
                        end)
                        -- Highlight the target line fully (works for single-line too)
                        vim.api.nvim_buf_clear_namespace(self.vbuf, NS_PREVIEW, 0, -1)
                        vim.api.nvim_buf_set_extmark(self.vbuf, NS_PREVIEW, lnum - 1, 0, {
                            end_row = lnum, -- makes it "multiline" → enables hl_eol
                            hl_group = "Visual",
                            hl_eol = true,
                            hl_mode = "blend",
                        })
                    end
                end
            end
        end
    )
    assert(type(self.async_preview_cancel) == "function")
end

--------------------------------------------------------------------------------
-- Spinner
--------------------------------------------------------------------------------

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

--------------------------------------------------------------------------------
-- List manipulation
--------------------------------------------------------------------------------

function Picker:request_clear_preview()
    if self.vbuf and self.vbuf > 0. and not self.preview_timer then
        -- Defer clearing the preview window to avoid flicker during fast scrolls
        ---@diagnostic disable-next-line: undefined-field
        local timer = vim.loop.new_timer()
        self.preview_timer = timer
        timer:start(self.antiflicker_delay, 0, vim.schedule_wrap(function()
            if self.closed then return end
            vim.api.nvim_buf_set_lines(self.vbuf, 0, -1, false, {})
            self.preview_timer = nil
        end))
        return
    end
end

function Picker:cancel_clear_preview_req()
    self.preview_timer = fntools.stop_and_close_timer(self.preview_timer)
end

function Picker:clear_list()
    self.items_data = {}

    vim.api.nvim_buf_set_lines(self.lbuf, 0, -1, false, {})
    vim.api.nvim_buf_clear_namespace(self.lbuf, NS_VIRT, 0, -1)
    self:request_clear_preview()
    vim.wo[self.lwin].cursorline = false
    self:render_ui()
end

function Picker:add_new_lines(items, query)
    local prefix = "  "
    local lines = {}
    local extmarks = {}
    local virt_extmarks = {}

    -- 1. Check if the buffer is currently "fresh" (one empty line)
    local current_buf_count = vim.api.nvim_buf_line_count(self.lbuf)
    local is_empty = current_buf_count == 1 and vim.api.nvim_buf_get_lines(self.lbuf, 0, 1, false)[1] == ""

    -- 2. Determine where we start counting rows for highlights
    local start_row = is_empty and 0 or current_buf_count

    for _, item in ipairs(items) do
        local label = item.label
        local label_chunks = item.label_chunks
        if label then
            label = label:gsub("\n", "")
        elseif label_chunks then
            local parts = {}
            for _, chunk in ipairs(item.label_chunks) do
                if chunk[1] then parts[#parts + 1] = chunk[1] end
            end
            label = table.concat(parts)
            label = label:gsub("\n", "")
        else
            label = ""
        end

        table.insert(lines, prefix .. label)
        table.insert(self.items_data, item.data)

        local row = start_row + #lines - 1
        local col = #prefix

        if label_chunks then
            for _, chunk in ipairs(label_chunks) do
                local text, hl = chunk[1], chunk[2]
                if text and #text > 0 then
                    if hl then
                        table.insert(extmarks, { row = row, col_start = col, col_end = col + #text, hl_group = hl })
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
            table.insert(virt_extmarks, { row = row, col = 0, opts = { virt_lines = vlines, hl_mode = "blend" } })
        end
    end

    if #lines == 0 then return end

    -- 3. Apply the changes to the buffer
    if is_empty then
        -- Replace the initial blank line entirely
        vim.api.nvim_buf_set_lines(self.lbuf, 0, -1, false, lines)
    else
        -- Append to existing items
        vim.api.nvim_buf_set_lines(self.lbuf, start_row, start_row, false, lines)
    end

    -- 4. Apply highlights and virtual lines
    for _, mark in ipairs(extmarks) do
        vim.api.nvim_buf_set_extmark(self.lbuf, NS_VIRT, mark.row, mark.col_start, {
            end_col = mark.col_end,
            hl_group = mark.hl_group,
        })
    end

    for _, mark in ipairs(virt_extmarks) do
        vim.api.nvim_buf_set_extmark(self.lbuf, NS_VIRT, mark.row, mark.col, mark.opts)
    end

    vim.wo[self.lwin].cursorline = true

    -- 5. Final validation
    local final_count = vim.api.nvim_buf_line_count(self.lbuf)
    assert(#self.items_data == final_count, string.format("Data (%d) != Buf (%d)", #self.items_data, final_count))
end

--------------------------------------------------------------------------------
-- Fetch
--------------------------------------------------------------------------------

---@param query string
function Picker:run_fetch(query)
    -- Record if the query actually changed (to reset cursor) vs. just appending results
    local is_new_query = (query ~= self.current_query)
    self.current_query = query

    if self.async_fetch_cancel then
        self.async_fetch_cancel()
        self.async_fetch_cancel = nil
    end

    self:stop_spinner()

    local fetch_opts = {
        list_width = math.max(1, self.layout.list_width - 2),
        list_height = self.layout.list_height,
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

            -- Capture current cursor before we modify the list
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

            -- If it's the very first render of a brand new query, go to top.
            -- Otherwise, keep the user's cursor where it was (clamped to list size).
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
        -- Return to a blank prompt if moving past the end
        self.history_idx = new_idx
        self:set_prompt_text("")
    end
end

---Helper to update the prompt and move cursor to end
function Picker:set_prompt_text(text)
    vim.api.nvim_buf_set_lines(self.pbuf, 0, -1, false, { text })
    vim.api.nvim_win_set_cursor(self.pwin, { 1, #text })
    -- The TextChanged autocmd will trigger run_fetch automatically
end

--------------------------------------------------------------------------------
-- Close
--------------------------------------------------------------------------------

---@param result any|nil
function Picker:close(result)
    if self.closed then return end
    self.closed = true

    self:stop_spinner()

    self.preview_timer = fntools.stop_and_close_timer(self.preview_timer)

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

    -- Save to history if provider exists and result was selected
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

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

function Picker:setup_input()
    local key_opts = { buffer = self.pbuf, nowait = true, silent = true }

    vim.keymap.set("i", "<CR>", function()
        self:close(self.items_data[self:get_cursor()])
    end, key_opts)

    vim.keymap.set("i", "<Esc>", function() self:close(nil) end, key_opts)
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

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = self.pbuf,
        callback = function()
            local query = vim.api.nvim_buf_get_lines(self.pbuf, 0, 1, false)[1] or ""
            self:run_fetch(query)
        end
    })
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

function Picker:start()
    self:setup_input()
    self:run_fetch("")

    vim.api.nvim_set_current_win(self.pwin)

    vim.schedule(function()
        vim.cmd("startinsert!")
    end)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

---@param opts loop.Picker.opts
---@param callback loop.Picker.Callback
function M.select(opts, callback)
    assert(opts.fetch or opts.async_fetch)

    local picker = Picker:new(opts, callback)
    picker:start()
end

return M
