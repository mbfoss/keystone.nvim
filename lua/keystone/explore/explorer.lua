local Spinner    = require("keystone.utils.Spinner")
local class      = require("keystone.utils.class")
local common     = require("keystone.utils.common")
local fsutils    = require("keystone.utils.fsutils")
local uitools    = require("keystone.utils.uitools")

---@mod keystone.picker
---@brief Floating async picker with fuzzy filtering and optional preview.

local M          = {}

local NS_CONTENT = vim.api.nvim_create_namespace("keystone_PickerContent")
local NS_SPINNER = vim.api.nvim_create_namespace("keystone_PickerSpinner")
local NS_PREVIEW = vim.api.nvim_create_namespace("keystone_PickerPreview")


local _antiflicker_delay = 200

---@class keystone.Explorer.Item
---@field label_chunks {[1]:string,[2]:string?}[]?
---@field virt_lines? {[1]:string,[2]:string?}[][]
---@field path_part string
---@field supports_preview boolean?
---@field selectable boolean?

---@class keystone.explorer.ListItem
---@field text string
---@field path_part string
---@field supports_preview boolean?
---@field selectable boolean?

---@alias keystone.Explorer.Callback fun(path:string[]?)

---@class keystone.Explorer.FetcherOpts
---@field list_width number
---@field list_height number

---@alias keystone.Explorer.AsyncFetcher fun(path:string[],opts:keystone.Explorer.FetcherOpts,callback:fun(new_items:keystone.Explorer.Item[]?)):fun()?

---@class keystone.Explorer.AsyncPreviewOpts
---@field viewport_with number?
---@field viewport_height number?

---@alias keystone.Explorer.AsyncPreviewData {content:string|string[]|nil,filetype:string?,filepath:string?,lnum:number?,col:number?,error_msg:string?}
---@alias keystone.Explorer.AsyncPreviewLoader fun(path:string[], opts:keystone.Explorer.AsyncPreviewOpts, callback:fun(preview:keystone.Explorer.AsyncPreviewData?)):fun()?

---@class keystone.Explorer.Opts
---@field prompt string
---@field initial_path string[]
---@field initial_cursor string?
---@field async_fetch keystone.Explorer.AsyncFetcher?
---@field enable_preview boolean?
---@field async_preview keystone.Explorer.AsyncPreviewLoader?
---@field height_ratio number?
---@field width_ratio number?
---@field list_width number?
---@field list_wrap boolean?
---@field enable_list_sep boolean?

---@class keystone.Explorer.Layout
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

---@param on_delete fun()
local function _create_buffer(on_delete)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].modifiable = false
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
---@return keystone.Explorer.Layout
local function _compute_layout(opts)
    local cols = vim.o.columns
    local lines = vim.o.lines

    local width = math.ceil(cols * _clamp(opts.width_ratio or 0.5, 0.1, 0.9))
    local total_height = math.ceil(lines * _clamp(opts.height_ratio or 0.8, 0.3, 0.95))

    local row = math.floor((lines - total_height) / 2)
    local col = math.floor((cols - width) / 2)

    if not opts.has_preview then
        return {
            list_row = row,
            list_col = col,
            list_width = width,
            list_height = total_height,

            prev_row = row,
            prev_col = col,
            prev_width = 0,
            prev_height = 0,
        }
    end

    -- split vertically: top=list, bottom=preview
    local spacing = 2
    local list_height = math.floor((total_height - spacing) / 3)
    local prev_height = total_height - list_height - spacing

    return {
        list_row = row,
        list_col = col,
        list_width = width,
        list_height = list_height,

        prev_row = row + list_height + spacing,
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

---@type keystone.Explorer.AsyncPreviewLoader
local function _default_preview(path, _, callback)
    local filepath = table.concat(path, '/')
    if not filepath or filepath == "" then
        vim.schedule(function()
            callback({})
        end)
        return function()
        end
    end
    if not fsutils.file_exists(filepath) then
        vim.schedule(function()
            callback({ error_msg = "Invalid file path: " .. tostring(filepath) })
        end)
        return function()
        end
    end
    local cancel_fn = fsutils.async_load_text_file(filepath, { max_size = 1024, timeout = 3000 },
        function(load_err, content)
            callback({
                content = content,
                filepath = filepath,
                error_msg = load_err,
            })
        end)
    return cancel_fn
end

---@class keystone.utils.Explorer
---@field new fun(self: keystone.utils.Explorer,opts:keystone.Explorer.Opts,callback:keystone.Explorer.Callback) : keystone.utils.Explorer
---@field opts keystone.Explorer.Opts
---@field callback keystone.Explorer.Callback
---@field layout keystone.Explorer.Layout
---@field lbuf integer
---@field vbuf integer?
---@field lwin integer
---@field vwin integer?
---@field spinner keystone.utils.Spinner?
---@field closed boolean
---@field list_items keystone.explorer.ListItem[]
---@field async_fetch_context number
---@field async_fetch_cancel fun()?
---@field async_preview_context number
---@field async_preview_cancel fun()?
---@field preview_timer table?
---@field nav_history string[]
local Explorer = class()

---@param opts keystone.Explorer.Opts
---@param callback keystone.Explorer.Callback
function Explorer:init(opts, callback)
    vim.validate("opts", opts, "table")
    vim.validate("opts", opts.initial_path, "table")
    vim.validate("callback", callback, "function")
    assert(#opts.initial_path > 0, "initial path path not be empty")

    self.opts = opts and vim.deepcopy(opts) or {}
    self.callback = callback

    self.preview_enabled = opts.enable_preview

    self._path = opts.initial_path ---@type string[]
    self.list_items = {} ---@type keystone.explorer.ListItem[]

    self.nav_history = {}
    for idx, part in ipairs(self._path) do
        self.nav_history[idx] = part
    end
    if opts.initial_cursor then
        self.nav_history[#self._path + 1] = opts.initial_cursor
    end

    self.closed = false

    self.async_fetch_context = 0
    self.async_fetch_cancel = nil

    self.async_preview_context = 0
    self.async_preview_cancel = nil

    self.spinner = nil

    self:setup_ui()
end

---@return nil
function Explorer:setup_ui()
    local opts = self.opts

    self.layout = _compute_layout {
        has_preview = false, -- initially, no preview
        height_ratio = opts.height_ratio,
        width_ratio = opts.width_ratio,
        list_width = opts.list_width
    }

    if self.opts.enable_list_sep then
        self.list_sep_line = string.rep("─", self.layout.list_width)
    end

    self.lbuf = _create_buffer(function()
        self.lbuf = nil
    end)

    assert(self.lbuf)
    vim.api.nvim_create_autocmd({ "CursorMoved" }, {
        buffer = self.lbuf,
        callback = function(ev)
            if not self.closed then
                local row = self:get_cursor()
                if row == self.last_cursor then
                    return
                end
                self.last_cursor = row
                local item = self.list_items[self:get_cursor()]
                if item then
                    self.nav_history[#self._path + 1] = item.path_part
                end
                self:update_preview()
            end
        end,
    })

    local base_cfg = {
        relative = "editor",
        style = "minimal",
        border = "rounded"
    }

    local lwin_augroup
    self.lwin, lwin_augroup = uitools.create_window(self.lbuf, false, vim.tbl_extend("force", base_cfg, {
            row = self.layout.list_row,
            col = self.layout.list_col,
            width = self.layout.list_width,
            height = self.layout.list_height
        }),
        function()
            self.lwin = nil
            vim.schedule(function()
                self:close()
            end)
        end)

    local winhl = "NormalFloat:Normal,FloatBorder:Normal"
    for _, w in ipairs({ self.lwin, self.vwin }) do
        if w then
            vim.wo[w].winhighlight = winhl
        end
    end

    vim.wo[self.lwin].wrap = self.opts.list_wrap ~= false

    ---@type number?
    vim.api.nvim_create_autocmd("WinEnter", {
        group = lwin_augroup,
        callback = function(args)
            local win = vim.api.nvim_get_current_win()
            assert(not self.closed)
            if win ~= self.lwin and win ~= self.vwin then
                vim.schedule(function()
                    self:close()
                end)
            end
        end
    })
    vim.api.nvim_create_autocmd("VimResized", {
        group = lwin_augroup,
        callback = function()
            assert(not self.closed)
            vim.schedule(function()
                self:on_resize()
            end)
        end
    })
end

function Explorer:on_resize()
    if self.closed then return end

    self.layout = _compute_layout {
        has_preview = self.vwin ~= nil,
        height_ratio = self.opts.height_ratio,
        width_ratio = self.opts.width_ratio,
        list_width = self.opts.list_width
    }

    if self.opts.enable_list_sep then
        self.list_sep_line = string.rep("─", self.layout.list_width)
    end

    local base = {
        relative = "editor",
    }

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

function Explorer:render_ui()
    if not vim.api.nvim_buf_is_valid(self.lbuf) then
        return
    end

    local total = #self.list_items
    if total == 0 then
        return
    end

    local cur = self:get_cursor()
end

---@return integer
function Explorer:get_cursor()
    return vim.api.nvim_win_get_cursor(self.lwin)[1]
end

---@param row integer
---@param force boolean?
---@param clamp boolean?
function Explorer:move_cursor(row, force, clamp)
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
function Explorer:update_preview()
    self.async_preview_context = self.async_preview_context + 1
    local preview_context = self.async_preview_context
    local fetch_context = self.async_fetch_context

    if self.closed then return end
    if not self.vbuf then return end

    if self.async_preview_cancel then
        self.async_preview_cancel()
        self.async_preview_cancel = nil
    end

    ---@type keystone.explorer.ListItem
    local item = self.list_items[self:get_cursor()]
    if not item or item.supports_preview == false then
        self:request_clear_preview(true)
        return
    end

    self:request_clear_preview()

    local path = vim.list_extend({}, self._path)
    table.insert(path, item.path_part)

    local preview_width = math.max(0, self.layout.prev_width - 2)   -- -2 for borders
    local preview_height = math.max(0, self.layout.prev_height - 2) -- -2 for borders

    local preview_fn = self.opts.async_preview or _default_preview

    self.async_preview_cancel = preview_fn(
        path,
        {
            viewport_with = preview_width,
            viewport_height = preview_height,
        },
        function(preview)
            if self.closed or preview_context ~= self.async_preview_context or fetch_context ~= self.async_fetch_context then return end
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

function Explorer:confirm()
    ---@type keystone.explorer.ListItem
    local item = self.list_items[self:get_cursor()]
    if not item then return end
    if not item.selectable then
        self:run_fetch("in")
        return
    end
    local path = vim.list_extend({}, self._path)
    table.insert(path, item.path_part)
    self:close(path)
end

function Explorer:toggle_preview()
    if not self.preview_enabled then return end
    if self.vwin then
        vim.api.nvim_win_close(self.vwin, true)
        self.vwin = nil
        if self.vbuf then
            vim.api.nvim_buf_delete(self.vbuf, { force = true })
            self.vbuf = nil
        end
        self:on_resize()
    else
        if not self.vbuf then
            self.vbuf = _create_buffer(function()
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
            list_width = self.opts.list_width
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

        self:on_resize()
        self:update_preview()
    end
end

function Explorer:start_spinner()
    if self.spinner then return end

    self.spinner = Spinner:new {
        interval = 80,
        on_update = function(frame)
            if not vim.api.nvim_buf_is_valid(self.lbuf) then return end
            vim.api.nvim_buf_clear_namespace(self.lbuf, NS_SPINNER, 0, -1)
            vim.api.nvim_buf_set_extmark(self.lbuf, NS_SPINNER, 0, 0, {
                virt_text = { { frame .. " ", "Comment" } },
                virt_text_pos = "right_align"
            })
        end
    }

    self.spinner:start()
end

function Explorer:stop_spinner()
    if self.spinner then
        self.spinner:stop()
        self.spinner = nil
    end
    vim.api.nvim_buf_clear_namespace(self.lbuf, NS_SPINNER, 0, -1)
end

---@param immediate  boolean?
function Explorer:request_clear_preview(immediate)
    local clear = function()
        if self.vbuf and not self.closed then
            vim.bo[self.vbuf].modifiable = true
            vim.api.nvim_buf_set_lines(self.vbuf, 0, -1, false, {})
            vim.bo[self.vbuf].modifiable = false
            vim.api.nvim_buf_clear_namespace(self.vbuf, NS_PREVIEW, 0, -1)
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

function Explorer:cancel_clear_preview_req()
    self.preview_timer = common.stop_and_close_timer(self.preview_timer)
end

function Explorer:clear_list()
    self.list_items = {}

    vim.bo[self.lbuf].modifiable = true
    vim.api.nvim_buf_set_lines(self.lbuf, 0, -1, false, {})
    vim.bo[self.lbuf].modifiable = false

    vim.api.nvim_buf_clear_namespace(self.lbuf, NS_CONTENT, 0, -1)
    self:request_clear_preview()
    vim.wo[self.lwin].cursorline = false
    self:render_ui()
end

---@param items keystone.Explorer.Item[]
function Explorer:add_new_lines(items)
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
        ---@type keystone.explorer.ListItem
        local list_item = {
            text = label,
            path_part = item.path_part,
            supports_preview = item.supports_preview,
            selectable = item.selectable,
        }
        local idx = #self.list_items + 1
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

---@param direction "in"|"out"|nil
function Explorer:run_fetch(direction)
    local cur = self:get_cursor()
    local cur_item = cur and self.list_items[cur] or nil

    if direction == "in" and cur_item and cur_item.selectable then
        return
    end

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

    self.async_fetch_context = self.async_fetch_context + 1
    local context = self.async_fetch_context

    local complete = false

    local path = vim.list_extend({}, self._path)
    if direction == "in" then
        local part = cur_item and cur_item.path_part or nil
        if not part then
            return
        end
        table.insert(path, part)
    elseif direction == "out" then
        if #path <= 1 then
            return
        end
        table.remove(path)
    end

    self.async_fetch_cancel = self.opts.async_fetch(
        path,
        fetch_opts,
        function(new_items)
            if complete or self.closed or context ~= self.async_fetch_context then return end
            self:stop_spinner()
            if #new_items > 0 or #path > 1 then
                self:clear_list()
                self:add_new_lines(new_items)
                self._path = path
                local row = 1
                local target_part = self.nav_history[#path + 1]
                if target_part then
                    for i, item in ipairs(self.list_items) do
                        if item.path_part == target_part then
                            row = i
                            break
                        end
                    end
                end
                self:move_cursor(row, true, true)
                local display_path = table.concat(self._path, '/')
                if display_path == "" then display_path = "/" end
                if self.lwin and vim.api.nvim_win_is_valid(self.lwin) then
                    vim.api.nvim_win_set_config(self.lwin, {
                        title = fsutils.smart_crop_path(display_path, fetch_opts.list_width),
                        title_pos = "left",
                    })
                end
            end
            complete = true
        end
    )
    assert(type(self.async_fetch_cancel) == "function")

    if not complete then
        self:start_spinner()
    end
end

---@param path string[]?
function Explorer:close(path)
    if self.closed then return end
    self.closed = true

    self:stop_spinner()

    self.preview_timer = common.stop_and_close_timer(self.preview_timer)

    if self.async_fetch_cancel then self.async_fetch_cancel() end
    if self.async_preview_cancel then self.async_preview_cancel() end

    for _, w in ipairs({ self.lwin, self.vwin }) do
        if w and vim.api.nvim_win_is_valid(w) then
            vim.api.nvim_win_close(w, true)
        end
    end

    for _, b in ipairs({ self.lbuf, self.vbuf }) do
        if b then
            vim.api.nvim_buf_delete(b, { force = true })
        end
    end

    vim.schedule(function()
        self.callback(path)
    end)
end

function Explorer:setup_input()
    do
        local lbuf_key_opts = _key_opts_of(self.lbuf)
        vim.keymap.set("n", "l", function() self:run_fetch("in") end, lbuf_key_opts)
        vim.keymap.set("n", "h", function() self:run_fetch("out") end, lbuf_key_opts)
        vim.keymap.set("n", "<CR>", function() self:confirm() end, lbuf_key_opts)
        vim.keymap.set("n", "<Esc>", function() self:close() end, lbuf_key_opts)
        vim.keymap.set("n", "<Tab>", function() self:toggle_preview() end, lbuf_key_opts)
    end
end

function Explorer:open()
    assert(not self._open_called)
    self._open_called = true

    self:setup_input()
    self:run_fetch(nil)

    vim.api.nvim_set_current_win(self.lwin)
end

---@param opts keystone.Explorer.Opts
---@param callback keystone.Explorer.Callback
function M.open(opts, callback)
    assert(opts.async_fetch)
    local picker = Explorer:new(opts, callback)
    picker:open()
end

return M
