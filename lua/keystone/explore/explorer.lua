local class              = require("keystone.utils.class")
local common             = require("keystone.utils.common")
local fsutils            = require("keystone.utils.fsutils")

---@mod keystone.explorer
---@brief Floating async explorer with fuzzy filtering and optional preview.

local M                  = {}

local NS_CURSOR          = vim.api.nvim_create_namespace("keystone_ExplorerCursor")
local NS_CONTENT         = vim.api.nvim_create_namespace("keystone_ExplorerContent")

local _antiflicker_delay = 200

---@class keystone.explorer.ItemData
---@field filepath string?
---@field [string] any

---@class keystone.Explorer.Item
---@field label_chunks {[1]:string,[2]:string?}[]?
---@field virt_lines? {[1]:string,[2]:string?}[][]
---@field data keystone.explorer.ItemData

---@class keystone.explorer.ListItem
---@field text string
---@field data keystone.explorer.ItemData

---@alias keystone.Explorer.Callback fun(data:keystone.explorer.ItemData?)

---@class keystone.Explorer.FetcherOpts
---@field list_width number
---@field list_height number


---@alias keystone.Explorer.Fetcher fun(current:keystone.explorer.ItemData?,direction:"in"|"out",opts:keystone.Explorer.FetcherOpts):keystone.Explorer.Item[]?,number?

---@class keystone.Explorer.AsyncPreviewOpts
---@field viewport_with number?
---@field viewport_height number?


---@alias keystone.Explorer.AsyncPreviewData {content:string|string[]|nil,filetype:string?,filepath:string?,error_msg:string?}
---@alias keystone.Explorer.AsyncPreviewLoader fun(data:keystone.explorer.ItemData, opts:keystone.Explorer.AsyncPreviewOpts, callback:fun(preview:keystone.Explorer.AsyncPreviewData?)):fun()?

---@class keystone.Explorer.opts
---@field prompt string
---@field fetch keystone.Explorer.Fetcher
---@field enable_preview boolean?
---@field async_preview keystone.Explorer.AsyncPreviewLoader?
---@field height_ratio number?
---@field width_ratio number?
---@field list_width number?
---@field list_wrap boolean?
---@field enable_list_sep boolean?

---@class keystone.Explorer.Layout
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
---@return keystone.Explorer.Layout
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
            list_width = math.floor(max_width / 2)
        end
        prev_width = 0
    end

    local total_height = math.ceil(lines * _clamp(opts.height_ratio or .7, 0.3, 0.8))
    local list_height = _clamp(total_height, 1, lines)

    local row = math.floor((lines - total_height - 1) / 2)
    local col = math.floor((cols - (list_width + prev_width + spacing)) / 2)

    return {
        list_row = row,
        list_col = col,
        list_width = list_width,
        list_height = list_height,

        prev_row = row,
        prev_col = col + list_width + spacing,
        prev_width = prev_width,
        prev_height = list_height
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
local function _default_preview(data, _, callback)
    local filepath = data and data.filepath or nil
    if not filepath or filepath == "" then
        vim.schedule(function()
            callback({})
        end)
        return function() end
    end
    if not fsutils.file_exists(filepath) then
        vim.schedule(function()
            callback({ error_msg = "Invalid file path: " .. tostring(filepath) })
        end)
        return function() end
    end
    local cancel_fn = fsutils.async_load_text_file(filepath, { max_size = 50 * 1024 * 1024, timeout = 3000 },
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
---@field new fun(self: keystone.utils.Explorer,opts:keystone.Explorer.opts,callback:keystone.Explorer.Callback) : keystone.utils.Explorer
---@field opts keystone.Explorer.opts
---@field callback keystone.Explorer.Callback
---@field has_preview boolean
---@field layout keystone.Explorer.Layout
---@field lbuf integer
---@field vbuf integer?
---@field lwin integer
---@field vwin integer?
---@field closed boolean
---@field list_items keystone.explorer.ListItem[]
---@field async_preview_context number
---@field async_preview_cancel fun()?
---@field preview_timer table?
---@field resize_augroup number?
local Explorer = class()

---@param opts keystone.Explorer.opts
---@param callback keystone.Explorer.Callback
function Explorer:init(opts, callback)
    vim.validate("opts", opts, "table")
    vim.validate("callback", callback, "function")

    self.opts = opts and vim.fn.copy(opts) or {}
    self.callback = callback

    self.has_preview = opts.enable_preview

    self.list_items = {} ---@type keystone.explorer.ListItem[]

    self.closed = false

    self.async_preview_context = 0
    self.async_preview_cancel = nil

    self:setup_ui()
end

---@return nil
function Explorer:setup_ui()
    local opts = self.opts

    self.layout = _compute_layout {
        has_preview = self.has_preview,
        height_ratio = opts.height_ratio,
        width_ratio = opts.width_ratio,
        list_width = opts.list_width
    }

    local title = opts.prompt and (" " .. opts.prompt .. " ") or ""

    if self.opts.enable_list_sep then
        self.list_sep_line = string.rep("─", self.layout.list_width)
    end

    self.lbuf = vim.api.nvim_create_buf(false, true)
    self.vbuf = self.has_preview and vim.api.nvim_create_buf(false, true) or nil

    vim.bo[self.lbuf].modifiable = false
    if self.vbuf then
        vim.bo[self.vbuf].modifiable = false
    end

    for _, b in ipairs({ self.lbuf, self.vbuf }) do
        if b then
            vim.bo[b].bufhidden = "wipe"
            vim.bo[b].buftype = "nofile"
            vim.bo[b].swapfile = false
            vim.bo[b].undolevels = -1
            vim.bo[b].modeline = false
            vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
                buffer = b,
                once = true,
                callback = function()
                    if not self.closed then
                        if (b == self.lbuf) then self.lbuf = -1 end
                        if (b == self.vbuf) then self.vbuf = -1 end
                        vim.schedule(function() self:close() end)
                    end
                end,
            })
        end
    end

    local base_cfg = {
        relative = "editor",
        style = "minimal",
        border = "rounded"
    }

    self.lwin = vim.api.nvim_open_win(self.lbuf, false, vim.tbl_extend("force", base_cfg, {
        row = self.layout.list_row,
        col = self.layout.list_col,
        width = self.layout.list_width,
        height = self.layout.list_height,
        title = title,
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
    for _, w in ipairs({ self.lwin, self.vwin }) do
        if w then
            vim.wo[w].winhighlight = winhl
        end
    end

    vim.wo[self.lwin].wrap = self.opts.list_wrap ~= false

    ---@type number?
    assert(not self.focus_augroup)
    self.focus_augroup = vim.api.nvim_create_augroup("keystone_pickerfocus_" .. self.lbuf, { clear = true })
    vim.api.nvim_create_autocmd("WinEnter", {
        group = self.focus_augroup,
        callback = function(args)
            local win = vim.api.nvim_get_current_win()
            assert(not self.closed)
            if win ~= self.lwin and win ~= self.vwin then
                local cfg = vim.api.nvim_win_get_config(win)
                --if cfg.relative == "" then -- skip popups
                vim.schedule(function()
                    self:close()
                end)
                --end
            end
        end
    })

    assert(not self.resize_augroup)
    self.resize_augroup = vim.api.nvim_create_augroup("keystone_pickerresize_" .. self.lbuf, { clear = true })
    vim.api.nvim_create_autocmd("VimResized", {
        group = self.resize_augroup,
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
        has_preview = self.has_preview,
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

    if total > 0 then
        vim.api.nvim_buf_set_extmark(self.lbuf, NS_CURSOR, cur - 1, 0, {
            virt_text = { { "> ", "Special" } },
            virt_text_pos = "overlay",
            priority = 200,
        })
    end
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

    if self.closed then return end
    if not self.vbuf then return end

    self:request_clear_preview()

    if self.async_preview_cancel then
        self.async_preview_cancel()
        self.async_preview_cancel = nil
    end

    ---@type keystone.explorer.ListItem
    local item = self.list_items[self:get_cursor()]

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
            if self.closed or preview_context ~= self.async_preview_context then return end
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
                else
                    vim.bo[self.vbuf].filetype = ""
                    vim.api.nvim_win_set_cursor(self.vwin, { 1, 0 })
                end
            end
        end
    )
    assert(type(self.async_preview_cancel) == "function")
end

function Explorer:request_clear_preview()
    if self.vbuf and self.vbuf > 0 and not self.preview_timer then
        self.preview_timer = vim.defer_fn(function()
            self.preview_timer = nil
            if self.closed then return end
            vim.bo[self.vbuf].modifiable = true
            vim.api.nvim_buf_set_lines(self.vbuf, 0, -1, false, {})
            vim.bo[self.vbuf].modifiable = false
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
            data = item.data,
        }
        table.insert(self.list_items, list_item)
        local idx = #self.list_items
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

---@param current keystone.explorer.ItemData?
---@param direction "in"|"out"
function Explorer:run_fetch(current, direction)
    self:request_clear_preview()
    local fetch_opts = {
        list_width = math.max(1, self.layout.list_width - 2), -- -2 for borders
        list_height = math.max(1, self.layout.list_height - 2),
    }
    self:clear_list()
    local items, initial = self.opts.fetch(current, direction, fetch_opts)
    if items then
        self:add_new_lines(items)
        self:move_cursor(initial or 1, true, true)
    end
end

---@param selected_data keystone.explorer.ItemData?
function Explorer:close(selected_data)
    if self.closed then return end
    self.closed = true

    self.preview_timer = common.stop_and_close_timer(self.preview_timer)
    if self.async_preview_cancel then self.async_preview_cancel() end

    if self.focus_augroup then
        vim.api.nvim_del_augroup_by_id(self.focus_augroup)
        self.focus_augroup = nil
    end

    if self.resize_augroup then
        vim.api.nvim_del_augroup_by_id(self.resize_augroup)
        self.resize_augroup = nil
    end

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

    vim.schedule(function()
        self.callback(selected_data)
    end)
end

function Explorer:setup_input()
    local confirm = function()
        ---@type keystone.explorer.ListItem
        local list_item = self.list_items[self:get_cursor()]
        self:close(list_item and list_item.data or nil)
    end

    local function key_opts_of(buf)
        return { buffer = buf, nowait = true, silent = true }
    end

    ---@param direction "in"|"out"
    local fetch_action = function(direction)
        local cur = self:get_cursor()
        if cur > #self.list_items then return end
        local item = self.list_items[cur]
        if not item then return end
        self:run_fetch(item.data, direction)
    end

    do
        local lbuf_key_opts = key_opts_of(self.lbuf)
        vim.keymap.set("n", "l", function() fetch_action("in") end, lbuf_key_opts)
        vim.keymap.set("n", "h", function() fetch_action("out") end, lbuf_key_opts)
        vim.keymap.set("n", "<CR>", confirm, lbuf_key_opts)
        vim.keymap.set("n", "<Esc>", function() self:close() end, lbuf_key_opts)
    end

    if self.vbuf then
        local vbuf_key_opts = key_opts_of(self.vbuf)
        vim.keymap.set("n", "<CR>", confirm, vbuf_key_opts)
        vim.keymap.set("n", "<Esc>", function() self:close() end, vbuf_key_opts)
    end
end

function Explorer:open()
    assert(not self._open_called)
    self._open_called = true

    self:setup_input()

    vim.api.nvim_set_current_win(self.lwin)
    self:run_fetch(nil, "in")
end

---@param opts keystone.Explorer.opts
---@param callback keystone.Explorer.Callback
function M.open(opts, callback)
    assert(opts.fetch)
    local explorer = Explorer:new(opts, callback)
    explorer:open()
end

return M
