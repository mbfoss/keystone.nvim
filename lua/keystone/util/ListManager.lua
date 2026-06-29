local Spinner     = require("keystone.util.Spinner")
local timer       = require("keystone.util.timer")
local fsutil      = require("keystone.util.fsutil")
local uitool      = require("keystone.util.uitool")
local floatwin    = require("keystone.util.floatwin")

---@mod keystone.ListManager
---@brief Floating manager for a flat list of items: select / add / remove / rename
---@brief with an optional async preview. A trimmed, tree-less sibling of the explorer.

local M           = {}

local _NS_CONTENT = vim.api.nvim_create_namespace("keystone_ListManagerContent")
local _NS_SPINNER = vim.api.nvim_create_namespace("keystone_ListManagerSpinner")
local _NS_PREVIEW = vim.api.nvim_create_namespace("keystone_ListManagerPreview")

local _antiflicker_delay = 200

---@class keystone.ListManager.Item
---@field label_chunks {[1]:string,[2]:string?}[]? Highlighted label segments
---@field virt_lines? {[1]:string,[2]:string?}[][] Extra virtual lines under the item
---@field supports_preview boolean? Set false to suppress preview for this item
---@field key string? Stable identity used to restore the cursor across refreshes
---@field data any Arbitrary payload handed back to the caller

---@class keystone.ListManager.FetcherOpts
---@field list_width number
---@field list_height number

--- Populate the list. May call `callback` synchronously or asynchronously. When
--- it resolves asynchronously it must return a cancel function.
---@alias keystone.ListManager.Finder fun(opts:keystone.ListManager.FetcherOpts, callback:fun(items:keystone.ListManager.Item[]?)):fun()?

---@class keystone.ListManager.PreviewOpts
---@field viewport_width number
---@field viewport_height number

---@alias keystone.ListManager.PreviewData {content:string|string[]|nil,filetype:string?,filepath:string?,lnum:number?,error_msg:string?}
---@alias keystone.ListManager.Previewer fun(item:keystone.ListManager.Item, opts:keystone.ListManager.PreviewOpts, callback:fun(preview:keystone.ListManager.PreviewData?)):(fun())?

---@class keystone.ListManager.ActionArgs
---@field item keystone.ListManager.Item
---@field data any

--- `on_done` optionally receives the key the cursor should land on after refresh.
---@alias keystone.ListManager.SelectHandler fun(item:keystone.ListManager.Item)
---@alias keystone.ListManager.AddHandler fun(on_done:fun(key:string?))
---@alias keystone.ListManager.MutateHandler fun(ctx:keystone.ListManager.ActionArgs, on_done:fun(key:string?))

---@class keystone.ListManager.Opts
---@field prompt string?
---@field finder keystone.ListManager.Finder
---@field enable_preview boolean?
---@field previewer keystone.ListManager.Previewer?
---@field height_ratio number?
---@field width_ratio number?
---@field list_wrap boolean?
---@field enable_list_sep boolean?
---@field initial_key string? Key to focus when the manager first opens
---@field empty_text string? Message shown when the list is empty
---@field close_on_select boolean? Close after a selection (default true)
---@field on_select keystone.ListManager.SelectHandler?
---@field on_add keystone.ListManager.AddHandler?
---@field on_remove keystone.ListManager.MutateHandler?
---@field on_rename keystone.ListManager.MutateHandler?

---@class keystone.ListManager.Layout
---@field list_row number
---@field list_col number
---@field list_width number
---@field list_height number
---@field preview_row number
---@field preview_col number
---@field preview_width number
---@field preview_height number

---@param v number
---@param min number
---@param max number
---@return number
local function _clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

---@param has_preview boolean
---@param width_ratio number?
---@param height_ratio number?
---@return keystone.ListManager.Layout
local function _compute_layout(has_preview, width_ratio, height_ratio)
    local cols = vim.o.columns
    local lines = vim.o.lines
    local spacing = has_preview and 2 or 0
    local half_spacing = math.floor(spacing / 2)

    local list_width = math.ceil(cols * _clamp(width_ratio or 0.4, 0.1, 0.8))

    local preview_width = 0
    if has_preview then
        local width = math.min(list_width * 2, cols)
        preview_width = _clamp(width - list_width - half_spacing, 1, width)
    end

    local height = math.ceil(lines * _clamp(height_ratio or 0.7, 0.3, 0.9))
    local total_width = list_width + preview_width + spacing
    local row = math.floor((lines - height) / 2)
    local col = math.floor((cols - total_width) / 2)

    return {
        list_row = row,
        list_col = col,
        list_width = list_width,
        list_height = height,
        preview_row = row,
        preview_col = col + list_width + spacing,
        preview_width = preview_width,
        preview_height = height,
    }
end

---@param msg string
---@param width number
---@param height number
---@return string[]
local function _center_message(msg, width, height)
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

---@param on_delete fun()
---@return integer buf
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
        callback = on_delete,
    })
    return buf
end

--- Default previewer: loads the file referenced by `item.data.filepath` and
--- centres it on `item.data.lnum`.
---@type keystone.ListManager.Previewer
local function _default_preview(item, preview_opts, callback)
    local data = item.data or {}
    local filepath = data.filepath
    if not filepath or filepath == "" then
        vim.schedule(function() callback({}) end)
        return
    end
    if not fsutil.file_exists(filepath) then
        vim.schedule(function()
            callback({ error_msg = "Invalid file path: " .. tostring(filepath) })
        end)
        return
    end
    local max_size = preview_opts.viewport_height * preview_opts.viewport_width
    return fsutil.async_load_text_file(filepath, { max_size = max_size, timeout = 3000 },
        function(load_err, content)
            callback({
                content   = content,
                filepath  = filepath,
                lnum      = data.lnum,
                error_msg = load_err,
            })
        end)
end

---@param buf integer
local function _key_opts_of(buf)
    return { buffer = buf, nowait = true, silent = true }
end

---@class keystone.util.ListManager
---@field opts keystone.ListManager.Opts
---@field layout keystone.ListManager.Layout
---@field lbuf integer?
---@field vbuf integer?
---@field lwin integer?
---@field vwin integer?
---@field spinner keystone.util.Spinner?
---@field closed boolean
---@field list_items keystone.ListManager.Item[]
---@field preview_enabled boolean
---@field async_fetch_context number
---@field async_fetch_cancel fun()?
---@field async_preview_context number
---@field async_preview_cancel fun()?
---@field preview_timer table?
local ListManager = {}
ListManager.__index = ListManager

function ListManager:new(...)
    local obj = setmetatable({}, self)
    if obj.init then obj:init(...) end
    return obj
end

---@param opts keystone.ListManager.Opts
function ListManager:init(opts)
    vim.validate({
        opts = { opts, "table" },
        finder = { opts.finder, "function" },
    })

    self.opts = vim.deepcopy(opts)
    self.preview_enabled = opts.enable_preview or false
    self.list_items = {}
    self.closed = false

    self.async_fetch_context = 0
    self.async_fetch_cancel = nil
    self.async_preview_context = 0
    self.async_preview_cancel = nil
    self.preview_timer = nil
    self.spinner = nil
    self._list_fresh = false
    self.last_cursor = nil

    self:relayout()
    self:setup_ui()
    self:setup_input()
    if self.lwin then vim.api.nvim_set_current_win(self.lwin) end
    self:refresh(opts.initial_key)
end

function ListManager:setup_ui()
    assert(self.lbuf)
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = self.lbuf,
        callback = function()
            if self.closed then return end
            local row = self:get_cursor()
            if not row or row == self.last_cursor then return end
            self.last_cursor = row
            self:update_preview()
        end,
    })
end

function ListManager:relayout()
    if self.closed then return end

    local has_preview = self.preview_enabled

    self.layout = _compute_layout(has_preview, self.opts.width_ratio, self.opts.height_ratio)

    if self.opts.enable_list_sep then
        self.list_sep_line = string.rep("─", self.layout.list_width)
    end

    local base_cfg = {
        relative = "editor",
        style = "minimal",
        border = "rounded",
    }
    local winhl = "NormalFloat:Normal,FloatBorder:Normal,FloatTitle:Title"
    local title = self.opts.prompt and (" %s "):format(self.opts.prompt) or nil

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
                height = self.layout.list_height,
                title = title,
                title_pos = title and "left" or nil,
            }),
            function()
                self.lwin = nil
                if not self.closed then
                    vim.schedule(function() self:close() end)
                end
            end)
        vim.wo[self.lwin].winhighlight = winhl
        vim.wo[self.lwin].wrap = self.opts.list_wrap ~= false
        vim.wo[self.lwin].cursorline = false

        assert(type(pwin_augroup) == "number")
        vim.api.nvim_create_autocmd("WinEnter", {
            group = pwin_augroup,
            callback = function()
                if self.closed then return end
                local win = vim.api.nvim_get_current_win()
                local cfg = vim.api.nvim_win_get_config(win)
                local is_float = cfg.relative and cfg.relative ~= ""
                if not is_float and win ~= self.lwin and win ~= self.vwin then
                    vim.schedule(function() self:close() end)
                end
            end,
        })
        vim.api.nvim_create_autocmd("VimResized", {
            group = pwin_augroup,
            callback = function()
                if self.closed then return end
                vim.schedule(function() self:relayout() end)
            end,
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
                self.vbuf = _create_buffer(function() self.vbuf = nil end)
                local vbuf_key_opts = _key_opts_of(self.vbuf)
                vim.keymap.set("n", "<CR>", function() self:confirm_select() end, vbuf_key_opts)
                vim.keymap.set("n", "<Esc>", function() self:close() end, vbuf_key_opts)
            end
            self.vwin = uitool.create_window(self.vbuf, false, vim.tbl_extend("force", base_cfg, {
                    row = self.layout.preview_row,
                    col = self.layout.preview_col,
                    width = self.layout.preview_width,
                    height = self.layout.preview_height,
                }),
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
function ListManager:get_cursor()
    if not self.lwin then return nil end
    return vim.api.nvim_win_get_cursor(self.lwin)[1]
end

---@param row integer
---@param force boolean?
function ListManager:move_cursor(row, force)
    if not self.lwin then return end
    if not force and row == self:get_cursor() then return end

    local total = #self.list_items
    if total == 0 then return end

    row = _clamp(row, 1, total)
    vim.api.nvim_win_set_cursor(self.lwin, { row, 0 })
    self.last_cursor = row
    self:update_preview()
end

---@return keystone.ListManager.Item?
function ListManager:_get_current()
    if self.closed then return nil end
    local row = self:get_cursor()
    return row and self.list_items[row] or nil
end

function ListManager:update_preview()
    self.async_preview_context = self.async_preview_context + 1
    local preview_context = self.async_preview_context
    local fetch_context = self.async_fetch_context

    if self.closed or not self.vbuf then return end

    if self.async_preview_cancel then
        self.async_preview_cancel()
        self.async_preview_cancel = nil
    end

    local item = self:_get_current()
    if not item or item.supports_preview == false then
        self:request_clear_preview(true)
        return
    end

    self:request_clear_preview()

    local preview_width = math.max(0, self.layout.preview_width - 2)
    local preview_height = math.max(0, self.layout.preview_height - 2)
    local preview_fn = self.opts.previewer or _default_preview

    self.async_preview_cancel = preview_fn(
        item,
        { viewport_width = preview_width, viewport_height = preview_height },
        function(preview)
            if self.closed
                or preview_context ~= self.async_preview_context
                or fetch_context ~= self.async_fetch_context then
                return
            end
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
                lines = _center_message(preview.error_msg, preview_width, preview_height)
            else
                lines = _center_message("No preview", preview_width, preview_height)
            end
            lines = lines or {}
            if not self.vbuf then return end

            self:cancel_clear_preview_req()
            vim.bo[self.vbuf].modifiable = true
            vim.api.nvim_buf_set_lines(self.vbuf, 0, -1, false, lines)
            vim.bo[self.vbuf].modifiable = false

            if content then
                local filetype = preview.filetype
                if not filetype and preview.filepath then
                    filetype = vim.filetype.match({ filename = preview.filepath })
                end
                vim.bo[self.vbuf].filetype = filetype or ""
                if preview.lnum then
                    local lnum = _clamp(preview.lnum, 1, #lines)
                    vim.api.nvim_win_set_cursor(self.vwin, { lnum, 0 })
                    vim.api.nvim_win_call(self.vwin, function() vim.cmd("normal! zz") end)
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
        end)
end

---@param immediate boolean?
function ListManager:request_clear_preview(immediate)
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

function ListManager:cancel_clear_preview_req()
    self.preview_timer = timer.stop_and_close_timer(self.preview_timer)
end

function ListManager:start_spinner()
    if self.spinner then return end
    self.spinner = Spinner:new {
        interval = 80,
        on_update = function(frame)
            if not self.lbuf then return end
            vim.api.nvim_buf_clear_namespace(self.lbuf, _NS_SPINNER, 0, -1)
            vim.api.nvim_buf_set_extmark(self.lbuf, _NS_SPINNER, 0, 0, {
                virt_text = { { frame .. " ", "Comment" } },
                virt_text_pos = "eol_right_align",
            })
        end,
    }
    self.spinner:start()
end

function ListManager:stop_spinner()
    if self.spinner then
        self.spinner:stop()
        self.spinner = nil
    end
    if self.lbuf then
        vim.api.nvim_buf_clear_namespace(self.lbuf, _NS_SPINNER, 0, -1)
    end
end

function ListManager:clear_list()
    self.list_items = {}
    vim.bo[self.lbuf].modifiable = true
    vim.api.nvim_buf_set_lines(self.lbuf, 0, -1, false, {})
    vim.bo[self.lbuf].modifiable = false
    vim.api.nvim_buf_clear_namespace(self.lbuf, _NS_CONTENT, 0, -1)
    self:request_clear_preview()
    vim.wo[self.lwin].cursorline = false
    self.last_cursor = nil
    self._list_fresh = true
end

---@param items keystone.ListManager.Item[]
function ListManager:add_new_lines(items)
    local prefix = "  "
    local is_fresh = self._list_fresh

    vim.bo[self.lbuf].modifiable = true
    for _, item in ipairs(items) do
        local label = ""
        if item.label_chunks then
            local parts = {}
            for _, chunk in ipairs(item.label_chunks) do
                table.insert(parts, chunk[1] or "")
            end
            label = table.concat(parts)
        end
        label = label:gsub("\n", " ")

        local idx = #self.list_items + 1
        table.insert(self.list_items, idx, item)

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
            table.insert(vlines, { { self.list_sep_line, "NonText" } })
        end
        if #vlines > 0 then
            vim.api.nvim_buf_set_extmark(self.lbuf, _NS_CONTENT, row, 0, {
                virt_lines = vlines,
                hl_mode = "blend",
            })
        end
    end
    vim.bo[self.lbuf].modifiable = false
    vim.wo[self.lwin].cursorline = #self.list_items > 0
end

function ListManager:_render_empty()
    local width = math.max(0, self.layout.list_width - 2)
    local height = math.max(0, self.layout.list_height - 2)
    local lines = _center_message(self.opts.empty_text or "Empty", width, height)
    vim.bo[self.lbuf].modifiable = true
    vim.api.nvim_buf_set_lines(self.lbuf, 0, -1, false, lines)
    vim.bo[self.lbuf].modifiable = false
    for row = 0, #lines - 1 do
        vim.api.nvim_buf_set_extmark(self.lbuf, _NS_CONTENT, row, 0, {
            end_row = row + 1,
            hl_group = "Comment",
            hl_eol = true,
        })
    end
end

--- Re-run the finder and rebuild the list, restoring the cursor onto `restore_key`
--- when it is still present.
---@param restore_key string|false|nil false = restore current row by index; nil = keep current key
---@param on_complete fun()?
function ListManager:refresh(restore_key, on_complete)
    if self.closed then return end

    local restore_row = self:get_cursor()
    if restore_key == nil then
        local item = restore_row and self.list_items[restore_row] or nil
        restore_key = item and item.key or nil
    end

    if self.async_fetch_cancel then
        self.async_fetch_cancel()
        self.async_fetch_cancel = nil
    end

    self:stop_spinner()
    self:request_clear_preview()

    local fetch_opts = {
        list_width = math.max(1, self.layout.list_width - 2),
        list_height = math.max(1, self.layout.list_height - 2),
    }

    self.async_fetch_context = self.async_fetch_context + 1
    local context = self.async_fetch_context
    local complete = false

    local on_items = function(new_items)
        if complete or self.closed or context ~= self.async_fetch_context then return end
        complete = true
        self:stop_spinner()
        new_items = new_items or {}
        self:clear_list()
        if #new_items == 0 then
            self:_render_empty()
        else
            self:add_new_lines(new_items)
            local row = restore_key == false and (restore_row or 1) or 1
            if restore_key and restore_key ~= false then
                for i, item in ipairs(self.list_items) do
                    if item.key == restore_key then
                        row = i
                        break
                    end
                end
            end
            self:move_cursor(row, true)
        end
        if on_complete then on_complete() end
    end

    self.async_fetch_cancel = self.opts.finder(fetch_opts, on_items)
    if not complete then self:start_spinner() end
end

function ListManager:confirm_select()
    local item = self:_get_current()
    if not item then return end
    if self.opts.on_select then
        self.opts.on_select(item)
    end
    if self.opts.close_on_select ~= false then
        self:close()
    end
end

function ListManager:_action_add()
    if not self.opts.on_add then return end
    self.opts.on_add(function(key)
        self:refresh(key)
    end)
end

function ListManager:_action_remove()
    if not self.opts.on_remove then return end
    local row = self:get_cursor()
    local item = row and self.list_items[row] or nil
    if not item then return end
    -- Land on the neighbour that survives the removal.
    local neighbour = self.list_items[row + 1] or self.list_items[row - 1]
    local restore_key = neighbour and neighbour.key or nil
    self.opts.on_remove({ item = item, data = item.data }, function()
        self:refresh(restore_key)
    end)
end

function ListManager:_action_rename()
    if not self.opts.on_rename then return end
    local item = self:_get_current()
    if not item then return end
    self.opts.on_rename({ item = item, data = item.data }, function(key)
        self:refresh(key or item.key)
    end)
end

---@class keystone.ListManager.Keymap
---@field label string Human-readable key(s) shown in the help menu
---@field keys string[] Keys to bind
---@field desc string Help description
---@field enabled boolean? Bind/list only when not false
---@field fn fun()

--- The single source of truth for both the bindings and the help menu, so they
--- can never drift apart.
---@return keystone.ListManager.Keymap[]
function ListManager:_keymaps()
    local o = self.opts
    return {
        { label = "<CR>",      keys = { "<CR>" },        desc = "Select / open item",
            fn = function() self:confirm_select() end },
        { label = "a",         keys = { "a" },           desc = "Add item",
            enabled = o.on_add ~= nil, fn = function() self:_action_add() end },
        { label = "r",         keys = { "r" },           desc = "Rename item",
            enabled = o.on_rename ~= nil, fn = function() self:_action_rename() end },
        { label = "d",         keys = { "d" },           desc = "Remove item",
            enabled = o.on_remove ~= nil, fn = function() self:_action_remove() end },
        { label = "R",         keys = { "R" },           desc = "Refresh list",
            fn = function() self:refresh() end },
        { label = "g?",        keys = { "g?" },          desc = "Show this help",
            fn = function() self:show_help() end },
        { label = "q / <Esc>", keys = { "q", "<Esc>" },  desc = "Close",
            fn = function() self:close() end },
    }
end

function ListManager:setup_input()
    local opts = _key_opts_of(self.lbuf)
    for _, m in ipairs(self:_keymaps()) do
        if m.enabled ~= false then
            for _, key in ipairs(m.keys) do
                vim.keymap.set("n", key, m.fn, opts)
            end
        end
    end
end

--- Opens a floating cheat-sheet of the active keymaps.
function ListManager:show_help()
    local entries = {}
    local key_width = 0
    for _, m in ipairs(self:_keymaps()) do
        if m.enabled ~= false then
            key_width = math.max(key_width, #m.label)
            entries[#entries + 1] = m
        end
    end

    local lines = {}
    for _, m in ipairs(entries) do
        lines[#lines + 1] = string.format("  %-" .. key_width .. "s   %s", m.label, m.desc)
    end

    floatwin.open(table.concat(lines, "\n"), {
        title = (self.opts.prompt or "List") .. " keymaps",
    })
end

function ListManager:close()
    if self.closed then return end
    self.closed = true

    self:stop_spinner()
    self.preview_timer = timer.stop_and_close_timer(self.preview_timer)

    if self.async_fetch_cancel then self.async_fetch_cancel() end
    if self.async_preview_cancel then self.async_preview_cancel() end

    for _, w in ipairs({ self.lwin, self.vwin }) do
        if w and vim.api.nvim_win_is_valid(w) then
            vim.api.nvim_win_close(w, true)
        end
    end
    for _, b in ipairs({ self.lbuf, self.vbuf }) do
        if b and vim.api.nvim_buf_is_valid(b) then
            vim.api.nvim_buf_delete(b, { force = true })
        end
    end
end

---@param opts keystone.ListManager.Opts
---@return keystone.util.ListManager
function M.open(opts)
    return ListManager:new(opts)
end

return M
