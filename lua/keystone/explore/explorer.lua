local Spinner    = require("keystone.util.Spinner")
local common     = require("keystone.util.timer")
local fsutil    = require("keystone.util.fsutil")
local uitool    = require("keystone.util.uitool")
local layouts    = require("keystone.explore.layouts")

---@mod keystone.picker
---@brief Floating async picker with fuzzy filtering and optional preview.

local M          = {}

local _NS_CONTENT = vim.api.nvim_create_namespace("keystone_PickerContent")
local _NS_SPINNER = vim.api.nvim_create_namespace("keystone_PickerSpinner")
local _NS_PREVIEW = vim.api.nvim_create_namespace("keystone_PickerPreview")


local _antiflicker_delay = 200

---@class keystone.Explorer.Item
---@field label_chunks {[1]:string,[2]:string?}[]?
---@field virt_lines? {[1]:string,[2]:string?}[][]
---@field name string
---@field supports_preview boolean?
---@field selectable boolean?
---@field data any

---@class keystone.explorer.ListItem
---@field text string
---@field name string
---@field supports_preview boolean?
---@field selectable boolean?
---@field data any

---@alias keystone.Explorer.Callback fun(path:string[]?)

---@class keystone.Explorer.FetcherOpts
---@field list_width number
---@field list_height number
---@field show_hidden boolean Whether hidden items should be included (interpretation is finder-defined)

---@alias keystone.Explorer.Finder fun(path:string[],opts:keystone.Explorer.FetcherOpts,callback:fun(new_items:keystone.Explorer.Item[]?)):fun()?

---@class keystone.Explorer.AsyncPreviewOpts
---@field viewport_width number
---@field viewport_height number

---@alias keystone.Explorer.AsyncPreviewData {content:string|string[]|nil,filetype:string?,filepath:string?,lnum:number?,col:number?,error_msg:string?}
---@alias keystone.Explorer.AsyncPreviewLoader fun(path:string[], opts:keystone.Explorer.AsyncPreviewOpts, callback:fun(preview:keystone.Explorer.AsyncPreviewData?)):fun()?

---@class keystone.Explorer.ActionArgs
---@field path string[]?
---@field data any
---@field is_dir boolean?
---@field recursive boolean?

---@alias keystone.Explorer.CreateHandler fun(ctx:keystone.Explorer.ActionArgs, on_done:fun(name:string))
---@alias keystone.Explorer.DeleteHandler fun(ctx:keystone.Explorer.ActionArgs, on_done:fun())
---@alias keystone.Explorer.RenameHandler fun(ctx:keystone.Explorer.ActionArgs, on_done:fun(name:string))

---@class keystone.Explorer.Opts
---@field prompt string
---@field initial_path string[]
---@field initial_cursor string?
---@field finder keystone.Explorer.Finder?
---@field enable_preview boolean?
---@field show_hidden boolean? Initial visibility of hidden items (default false). Toggled at runtime.
---@field previewer keystone.Explorer.AsyncPreviewLoader?
---@field height_ratio number?
---@field width_ratio number?
---@field list_wrap boolean?
---@field enable_list_sep boolean?
---@field on_create keystone.Explorer.CreateHandler?
---@field on_rename keystone.Explorer.RenameHandler?
---@field on_delete keystone.Explorer.DeleteHandler?

---@class keystone.Explorer.Layout
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
local function _default_preview(path, preview_opts, callback)
    local filepath = table.concat(path, '/')
    if not filepath or filepath == "" then
        vim.schedule(function()
            callback({})
        end)
        return function()
        end
    end
    if not fsutil.file_exists(filepath) then
        vim.schedule(function()
            callback({ error_msg = "Invalid file path: " .. tostring(filepath) })
        end)
        return function()
        end
    end
    local max_size = preview_opts.viewport_height * preview_opts.viewport_width
    local cancel_fn = fsutil.async_load_text_file(filepath, { max_size = max_size, timeout = 3000 },
        function(load_err, content)
            callback({
                content = content,
                filepath = filepath,
                error_msg = load_err,
            })
        end)
    return cancel_fn
end

---@class keystone.util.Explorer
---@field new fun(self: keystone.util.Explorer,opts:keystone.Explorer.Opts,callback:keystone.Explorer.Callback) : keystone.util.Explorer
---@field opts keystone.Explorer.Opts
---@field callback keystone.Explorer.Callback
---@field layout keystone.Explorer.Layout
---@field lbuf integer
---@field vbuf integer?
---@field lwin integer
---@field vwin integer?
---@field spinner keystone.util.Spinner?
---@field closed boolean
---@field list_items keystone.explorer.ListItem[]
---@field async_fetch_context number
---@field async_fetch_cancel fun()?
---@field async_preview_context number
---@field async_preview_cancel fun()?
---@field preview_timer table?
---@field nav_history string[]
---@field show_hidden boolean
local Explorer = {}
Explorer.__index = Explorer

function Explorer:new(...)
    local obj = setmetatable({}, self)
    if obj.init then obj:init(...) end
    return obj
end

---@param opts keystone.Explorer.Opts
---@param callback keystone.Explorer.Callback
function Explorer:init(opts, callback)
    vim.validate({
        opts = { opts, "table" },
        initial_path = { opts.initial_path, "table" },
        callback = { callback, "function" },
    })
    assert(#opts.initial_path > 0, "initial path path not be empty")

    self.opts = vim.deepcopy(opts)
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

    self.show_hidden = opts.show_hidden or false

    self.async_fetch_context = 0
    self.async_fetch_cancel = nil

    self.async_preview_context = 0
    self.async_preview_cancel = nil

    self._list_fresh = false
    self.spinner = nil

    self:setup_ui()
    self:setup_input()
    vim.api.nvim_set_current_win(self.lwin)
    self:run_fetch(nil)
end

---@return nil
function Explorer:setup_ui()
    self:relayout()

    assert(self.lbuf)
    vim.api.nvim_create_autocmd({ "CursorMoved" }, {
        buffer = self.lbuf,
        callback = function(ev)
            if not self.closed then
                local row = self:get_cursor()
                if not row or row == self.last_cursor then
                    return
                end
                self.last_cursor = row
                local item = self.list_items[row]
                if item then
                    self.nav_history[#self._path + 1] = item.name
                end
                self:update_preview()
            end
        end,
    })
end

---@param action "show_preview"|"hide_preview"|nil
function Explorer:relayout(action)
    if self.closed then return end

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

    if not self.lwin then
        if not self.lbuf then
            self.lbuf = _create_buffer(function()
                self.lbuf = nil
                if not self.closed then
                    vim.schedule(function() self:close() end)
                end
            end)
        end
        local pwin_augroup
        self.lwin, pwin_augroup = uitool.create_window(self.lbuf, false, vim.tbl_extend("force", base_cfg, {
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

        assert(type(pwin_augroup) == "number")
        vim.api.nvim_create_autocmd("WinEnter", {
            group = pwin_augroup,
            callback = function(args)
                local win = vim.api.nvim_get_current_win()
                if self.closed then return end
                local cfg = vim.api.nvim_win_get_config(win)
                local is_float = cfg.relative and cfg.relative ~= ""
                if not is_float and win ~= self.lwin and win ~= self.vwin then
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
                self.vbuf = _create_buffer(function()
                    self.vbuf = nil
                end)
                local vbuf_key_opts = _key_opts_of(self.vbuf)
                vim.keymap.set("n", "<CR>", function() self:confirm_choice() end, vbuf_key_opts)
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

---@return integer?
function Explorer:get_cursor()
    if not self.lwin then return nil end
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

    local cursor = self:get_cursor()

    ---@type keystone.explorer.ListItem?
    local item = cursor and self.list_items[cursor] or nil
    if not item or item.supports_preview == false then
        self:request_clear_preview(true)
        return
    end

    self:request_clear_preview()

    local path = vim.list_extend({}, self._path)
    table.insert(path, item.name)

    local preview_width = math.max(0, self.layout.preview_width - 2)   -- -2 for borders
    local preview_height = math.max(0, self.layout.preview_height - 2) -- -2 for borders

    local preview_fn = self.opts.previewer or _default_preview

    self.async_preview_cancel = preview_fn(
        path,
        {
            viewport_width = preview_width,
            viewport_height = preview_height,
        },
        function(preview)
            if self.closed or preview_context ~= self.async_preview_context or fetch_context ~= self.async_fetch_context then return end
            preview = preview or {}
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
                        vim.api.nvim_buf_clear_namespace(self.vbuf, _NS_PREVIEW, 0, -1)
                        vim.api.nvim_buf_set_extmark(self.vbuf, _NS_PREVIEW, lnum - 1, 0, {
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

---@return string[]?, keystone.explorer.ListItem?
function Explorer:_get_current()
    if self.closed then return end
    local row = self:get_cursor()
    local item = row and self.list_items[row] or nil
    if not item then return end
    local path = vim.list_extend({}, self._path)
    table.insert(path, item.name)
    return path, item
end

function Explorer:confirm_choice()
    local path, item = self:_get_current()
    if not item then return end
    if not item.selectable then
        self:run_fetch("in")
        return
    end
    self:close(path)
end

function Explorer:toggle_preview()
    if not self.preview_enabled then return end
    self:relayout(self.vwin ~= nil and "hide_preview" or "show_preview")
end

function Explorer:toggle_hidden()
    self.show_hidden = not self.show_hidden
    self:run_fetch(nil)
end

function Explorer:start_spinner()
    if self.spinner then return end

    self.spinner = Spinner:new {
        interval = 80,
        on_update = function(frame)
            if not self.lbuf then return end
            vim.api.nvim_buf_clear_namespace(self.lbuf, _NS_SPINNER, 0, -1)
            vim.api.nvim_buf_set_extmark(self.lbuf, _NS_SPINNER, 0, 0, {
                virt_text = { { frame .. " ", "Comment" } },
                virt_text_pos = "eol_right_align"
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
    if self.lbuf then
        vim.api.nvim_buf_clear_namespace(self.lbuf, _NS_SPINNER, 0, -1)
    end
end

---@param immediate  boolean?
function Explorer:request_clear_preview(immediate)
    local clear = function()
        if self.vbuf and not self.closed then
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

function Explorer:cancel_clear_preview_req()
    self.preview_timer = common.stop_and_close_timer(self.preview_timer)
end

function Explorer:clear_list()
    self.list_items = {}

    vim.bo[self.lbuf].modifiable = true
    vim.api.nvim_buf_set_lines(self.lbuf, 0, -1, false, {})
    vim.bo[self.lbuf].modifiable = false

    vim.api.nvim_buf_clear_namespace(self.lbuf, _NS_CONTENT, 0, -1)
    self:request_clear_preview()
    vim.wo[self.lwin].cursorline = false
    self._list_fresh = true
end

---@param items keystone.Explorer.Item[]
function Explorer:add_new_lines(items)
    local prefix = "  "
    local is_fresh = self._list_fresh

    vim.bo[self.lbuf].modifiable = true
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
        label = label:gsub("\n", " ")
        -- insert in list data
        ---@type keystone.explorer.ListItem
        local list_item = {
            text = label,
            name = item.name,
            supports_preview = item.supports_preview,
            selectable = item.selectable,
            data = item.data,
        }
        local idx = #self.list_items + 1
        table.insert(self.list_items, idx, list_item)
        -- insert in list buf
        local line_text = prefix .. label
        local row = idx - 1
        if is_fresh and idx == 1 then
            vim.api.nvim_buf_set_lines(self.lbuf, 0, 1, false, { line_text })
            is_fresh = false
            self._list_fresh = false
        else
            vim.api.nvim_buf_set_lines(self.lbuf, row, row, false, { line_text })
        end
        if item.label_chunks then
            local col = #prefix
            for _, chunk in ipairs(item.label_chunks) do
                local text, hl = chunk[1], chunk[2]
                if text and #text > 0 then
                    if hl then
                        vim.api.nvim_buf_set_extmark(self.lbuf, _NS_CONTENT, row, col, {
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
            vim.api.nvim_buf_set_extmark(self.lbuf, _NS_CONTENT, row, 0, {
                virt_lines = vlines,
                hl_mode = "blend"
            })
        end
    end
    vim.bo[self.lbuf].modifiable = false
    vim.wo[self.lwin].cursorline = #self.list_items > 0
end

---@param direction "in"|"out"|nil
---@param on_complete fun()?
function Explorer:run_fetch(direction, on_complete)
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
        show_hidden = self.show_hidden,
    }

    self.async_fetch_context = self.async_fetch_context + 1
    local context = self.async_fetch_context

    local complete = false

    local path = vim.list_extend({}, self._path)
    if direction == "in" then
        local part = cur_item and cur_item.name or nil
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

    self.async_fetch_cancel = self.opts.finder(
        path,
        fetch_opts,
        function(new_items)
            if complete or self.closed or context ~= self.async_fetch_context then return end
            self:stop_spinner()
            new_items = new_items or {}
            self:clear_list()
            self:add_new_lines(new_items)
            self._path = path
            local row = 1
            local target_part = self.nav_history[#path + 1]
            if target_part then
                for i, item in ipairs(self.list_items) do
                    if item.name == target_part then
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
                    title = fsutil.smart_crop_path(display_path, fetch_opts.list_width),
                    title_pos = "left",
                })
            end
            complete = true
            if on_complete then
                on_complete()
            end
        end
    )

    if not complete then
        assert(type(self.async_fetch_cancel) == "function",
            "finder deferred result should return a function")
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
    local opts = _key_opts_of(self.lbuf)

    vim.keymap.set("n", "l", function() self:run_fetch("in") end, opts)
    vim.keymap.set("n", "h", function() self:run_fetch("out") end, opts)
    vim.keymap.set("n", "<CR>", function() self:confirm_choice() end, opts)
    vim.keymap.set("n", "<Esc>", function() self:close() end, opts)
    vim.keymap.set("n", "<Tab>", function() self:toggle_preview() end, opts)
    vim.keymap.set("n", ".", function() self:toggle_hidden() end, opts)
    vim.keymap.set("n", "a", function() self:_action_create(false) end, opts)
    vim.keymap.set("n", "A", function() self:_action_create(true) end, opts)
    vim.keymap.set("n", "r", function() self:_action_rename() end, opts)
    vim.keymap.set("n", "d", function() self:_action_delete(false) end, opts)
    vim.keymap.set("n", "D", function() self:_action_delete(true) end, opts)
end

---@param name string
function Explorer:_get_item_row(name)
    for i, item in ipairs(self.list_items) do
        if item.name == name then
            return i
        end
    end
    return nil
end

---@private
---@param as_dir boolean
function Explorer:_action_create(as_dir)
    if not self.opts.on_create then return end
    local path_str = vim.inspect(self._path)
    ---@param name string
    local on_done = function(name)
        if path_str ~= vim.inspect(self._path) then return end
        self:run_fetch(nil, function()
            local row = self:_get_item_row(name)
            if row then self:move_cursor(row, false, false) end
        end)
    end
    ---@type keystone.Explorer.ActionArgs
    local args = {
        path = vim.list_extend({}, self._path),
        is_dir = as_dir
    }
    self.opts.on_create(args, on_done)
end

function Explorer:_action_rename()
    if not self.opts.on_rename then return end
    local path_str = vim.inspect(self._path)
    ---@param name string
    local on_done = function(name)
        if path_str ~= vim.inspect(self._path) then return end
        self:run_fetch(nil, function()
            local row = self:_get_item_row(name)
            if row then self:move_cursor(row, false, false) end
        end)
    end
    ---@type keystone.Explorer.ActionArgs
    local args = {
        path = self:_get_current(),
    }
    self.opts.on_rename(args, on_done)
end

---@private
---@param recursive boolean
function Explorer:_action_delete(recursive)
    if not self.opts.on_delete then return end
    local path_str = vim.inspect(self._path)
    local on_done = function()
        if path_str ~= vim.inspect(self._path) then return end
        local row = self:get_cursor()
        self:run_fetch(nil, function()
            if row then self:move_cursor(row, false, false) end
        end)
    end
    ---@type keystone.Explorer.ActionArgs
    local args = {
        path = self:_get_current(),
        recursive = recursive,
    }
    self.opts.on_delete(args, on_done)
end

---@param opts keystone.Explorer.Opts
---@param callback keystone.Explorer.Callback
function M.open(opts, callback)
    assert(opts.finder)
    Explorer:new(opts, callback)
end

return M
