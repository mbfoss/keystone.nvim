local TreeBuffer = require("keystone.tk.TreeBuffer")
local ui         = require("keystone.tk.ui")
local floatwin   = require("keystone.tk.floatwin")
local throttle   = require("keystone.tk.throttle")
local kinds      = require("keystone.symboltree.kinds")
local symbols    = require("keystone.symboltree.symbols")

---@class keystone.symboltree.ItemData
---@field name string
---@field detail string?
---@field kind integer
---@field icon string
---@field icon_hl string
---@field lnum integer
---@field col integer
---@field end_lnum integer
---@field is_current boolean?

--- Id of the single placeholder node shown when there is nothing to display.
local _placeholder_id = {}

local function _show_help()
    local help_text = { [[
NAVIGATION
==========
`<CR>`    Jump to symbol
`o`       Jump to symbol, keep focus in the tree

FOLDING
=======
`za`      Toggle expand/collapse
`zc`      Collapse
`zo`      Expand
`zC`      Collapse (recursive)
`zO`      Expand (recursive)

OTHER
=====
`K`       Hover info (kind, detail, position)
`R`       Refresh symbols
`g?`      Show this help]]
    }

    floatwin.open(table.concat(help_text, "\n"), {
        title = "Symbol Tree",
        is_markdown = true,
    })
end

---@param id any
---@param data keystone.symboltree.ItemData
---@return string[][] chunks, string[][] virt_chunks
local function _symbol_formatter(id, data)
    if not data then return {}, {} end

    local chunks = {
        { data.icon, data.icon_hl },
        { " " },
        { data.name, data.is_current and "Visual" or nil },
    }
    if data.detail and data.detail ~= "" then
        table.insert(chunks, { " " })
        table.insert(chunks, { data.detail, "Comment" })
    end

    local virt_chunks = {}
    if data.lnum > 0 then
        table.insert(virt_chunks, { tostring(data.lnum), "LineNr" })
    end
    return chunks, virt_chunks
end

local function _is_regular_buffer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then return false end
    return vim.bo[bufnr].buftype == ""
end

---@param bufnr integer
---@return vim.lsp.Client?
local function _symbol_client(bufnr)
    local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/documentSymbol" })
    return clients[1]
end

---@class keystone.SymbolTree.Opts
---@field track_cursor boolean? follow the cursor in the source buffer (default true)
---@field auto_expand boolean? expand every symbol on load (default true)
---@field show_detail boolean? show the server-provided detail text (default true)
---@field exclude_kinds string[]? `keystone.symboltree.kinds` names to hide
---@field debounce_ms integer? edit-to-refresh delay (default 500)

---@class keystone.SymbolTree
---@field new fun(self:keystone.SymbolTree, opts:keystone.SymbolTree.Opts?):keystone.SymbolTree
---@field private _treebuf keystone.tk.TreeBuffer
---@field private _source_buf integer
---@field private _symbols keystone.symboltree.Symbol[]
---@field private _excluded table<integer, true>
local SymbolTree = {}
SymbolTree.__index = SymbolTree

function SymbolTree:new(...)
    local obj = setmetatable({}, self)
    if obj.init then obj:init(...) end
    return obj
end

---@param opts keystone.SymbolTree.Opts?
function SymbolTree:init(opts)
    self._opts = opts and vim.deepcopy(opts) or {}
    self._source_buf = -1
    self._symbols = {}
    self._request_counter = 0
    self._current_id = nil
    self._autocmd_ids = {}

    -- Kind names are friendlier to configure than the numeric LSP codes, so
    -- resolve them to codes once here.
    self._excluded = {}
    for _, name in ipairs(self._opts.exclude_kinds or {}) do
        for code, kind in pairs(kinds.kinds) do
            if kind.name:lower() == name:lower() then
                self._excluded[code] = true
            end
        end
    end

    self._refresh_fn = throttle.debounce_wrap(self._opts.debounce_ms or 500, function()
        self:_request_symbols()
    end)

    self:_setup_tree()
end

function SymbolTree:_setup_tree()
    assert(not self._treebuf)

    self._treebuf = TreeBuffer.new({
        filetype = "keystone-symboltree",
        formatter = _symbol_formatter,
    })

    self._treebuf:subscribe({
        on_selection = function(id, data)
            self:_jump_to(data, true)
        end,
    })
end

---@return integer bufnr
function SymbolTree:create_buffer()
    local bufnr, created = self._treebuf:create_buffer(function()
        self:_on_buffer_deleted()
    end)

    if not created then return bufnr end

    local function with_item(fn)
        local item = self._treebuf:get_cursor_item()
        if item and item.id ~= _placeholder_id then fn(item) end
    end

    local keymaps = {
        ["o"] = {
            function()
                with_item(function(i) self:_jump_to(i.data, false) end)
            end,
            "Jump to symbol (keep focus)",
        },
        ["K"] = {
            function()
                with_item(function(i) self:_show_hover(i) end)
            end,
            "Show symbol info",
        },
        ["R"] = {
            function()
                self:_request_symbols()
            end,
            "Refresh symbols",
        },
        ["g?"] = {
            function()
                _show_help()
            end,
            "Show Help",
        },
    }

    assert(bufnr > 0)
    for key, map in pairs(keymaps) do
        vim.api.nvim_buf_set_keymap(bufnr, "n", key, "", { callback = map[1], desc = map[2] })
    end

    self:_on_buffer_created()

    return bufnr
end

function SymbolTree:get_bufnr()
    return self._treebuf:get_bufnr()
end

function SymbolTree:_on_buffer_created()
    assert(#self._autocmd_ids == 0)

    local function track(event, opts)
        self._autocmd_ids[#self._autocmd_ids + 1] = vim.api.nvim_create_autocmd(event, opts)
    end

    track({ "BufEnter", "BufWinEnter" }, {
        callback = function(args)
            if args.buf ~= self._treebuf:get_bufnr() and _is_regular_buffer(args.buf) then
                self:_set_source(args.buf)
            end
        end,
    })

    -- A reply is only valid for the buffer it was requested for, so re-request
    -- rather than trusting the cache when the server (re)attaches.
    track("LspAttach", {
        callback = function(args)
            if args.buf == self._source_buf then
                self:_request_symbols()
            end
        end,
    })

    track({ "TextChanged", "TextChangedI" }, {
        callback = function(args)
            if args.buf == self._source_buf then
                self._refresh_fn()
            end
        end,
    })

    if self._opts.track_cursor ~= false then
        track("CursorMoved", {
            callback = function(args)
                if args.buf == self._source_buf then
                    self:_sync_to_cursor()
                end
            end,
        })
    end

    local current = vim.api.nvim_get_current_buf()
    if _is_regular_buffer(current) then
        self:_set_source(current)
    else
        self:_show_placeholder("No symbols")
    end
end

function SymbolTree:_on_buffer_deleted()
    for _, id in ipairs(self._autocmd_ids) do
        vim.api.nvim_del_autocmd(id)
    end
    self._autocmd_ids = {}
    self._source_buf = -1
    self._symbols = {}
end

---@param bufnr integer
function SymbolTree:_set_source(bufnr)
    if bufnr == self._source_buf then return end
    self._source_buf = bufnr
    self._symbols = {}
    self._current_id = nil
    self:_request_symbols()
end

---@param text string
function SymbolTree:_show_placeholder(text)
    self._treebuf:clear_items()
    self._treebuf:add_item(nil, {
        id = _placeholder_id,
        data = { name = text, kind = 0, icon = "󰋗", icon_hl = "Comment", lnum = 0, col = 0, end_lnum = 0 },
    })
end

function SymbolTree:_request_symbols()
    local bufnr = self._source_buf
    if self._treebuf:get_bufnr() == -1 then return end
    if not vim.api.nvim_buf_is_valid(bufnr) then
        self:_show_placeholder("No buffer")
        return
    end

    local client = _symbol_client(bufnr)
    if not client then
        self:_show_placeholder("No LSP symbols")
        return
    end

    self._request_counter = self._request_counter + 1
    local request_id = self._request_counter

    local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
    client:request("textDocument/documentSymbol", params, function(err, result)
        -- Drop replies overtaken by a newer request, or for a buffer we have
        -- since navigated away from.
        if request_id ~= self._request_counter then return end
        if self._source_buf ~= bufnr then return end
        if self._treebuf:get_bufnr() == -1 then return end

        -- A null result can arrive as vim.NIL, so check the type.
        if err or type(result) ~= "table" or #result == 0 then
            self._symbols = {}
            self:_show_placeholder(err and "Symbol request failed" or "No symbols")
            return
        end

        self._symbols = symbols.normalize(result)
        self:_populate()
        self:_sync_to_cursor()
    end, bufnr)
end

--- Build the id for a symbol from its position in the tree. Position-based so
--- expansion state survives a refresh as long as the structure is unchanged.
---@param parent_id string?
---@param index integer
---@param symbol keystone.symboltree.Symbol
---@return string
local function _make_id(parent_id, index, symbol)
    return (parent_id or "") .. "/" .. index .. ":" .. symbol.name
end

---@param list keystone.symboltree.Symbol[]
---@param parent_id string?
---@return keystone.tk.TreeBuffer.ItemDef[]
function SymbolTree:_build_items(list, parent_id)
    local items = {}
    for index, symbol in ipairs(list) do
        if not self._excluded[symbol.kind] then
            local kind = kinds.get(symbol.kind)
            local id = _make_id(parent_id, index, symbol)
            local children = self:_build_items(symbol.children, id)
            items[#items + 1] = {
                id = id,
                expandable = #children > 0,
                expanded = self._opts.auto_expand ~= false,
                data = {
                    name     = symbol.name,
                    detail   = self._opts.show_detail ~= false and symbol.detail or nil,
                    kind     = symbol.kind,
                    icon     = kind.icon,
                    icon_hl  = kind.hl,
                    lnum     = symbol.lnum,
                    col      = symbol.col,
                    end_lnum = symbol.end_lnum,
                },
                children = children,
            }
        end
    end
    return items
end

---@param items table[]
---@param parent_id any?
function SymbolTree:_insert_items(items, parent_id)
    for _, item in ipairs(items) do
        local children = item.children
        item.children = nil
        self._treebuf:add_item(parent_id, item)
        self:_insert_items(children, item.id)
    end
end

function SymbolTree:_populate()
    self._treebuf:clear_items()
    self._current_id = nil
    local items = self:_build_items(self._symbols, nil)
    if #items == 0 then
        self:_show_placeholder("No symbols")
        return
    end
    self:_insert_items(items, nil)
end

--- Deepest item whose range covers `line`, walking down from the roots.
---@param line integer 1-based
---@return any? id
function SymbolTree:_find_item_at_line(line)
    local found = nil

    local function walk(items)
        for _, item in ipairs(items) do
            local data = item.data
            if data.lnum > 0 and line >= data.lnum and line <= data.end_lnum then
                found = item.id
                walk(self._treebuf:get_children(item.id))
                return
            end
        end
    end

    walk(self._treebuf:get_roots())
    return found
end

--- Highlight the symbol enclosing the source cursor and scroll it into view.
function SymbolTree:_sync_to_cursor()
    if self._opts.track_cursor == false then return end
    if self._treebuf:get_bufnr() == -1 then return end

    local winid = vim.fn.bufwinid(self._source_buf)
    if winid <= 0 then return end

    local line = vim.api.nvim_win_get_cursor(winid)[1]
    local id = self:_find_item_at_line(line)
    if id == self._current_id then return end

    if self._current_id then
        local previous = self._treebuf:get_item_data(self._current_id)
        if previous then
            previous.is_current = nil
            self._treebuf:refresh_item(self._current_id)
        end
    end

    self._current_id = id
    if not id then return end

    local data = self._treebuf:get_item_data(id)
    if data then
        data.is_current = true
        self._treebuf:refresh_item(id)
    end

    -- Only move the tree cursor when the tree is not the focused window, so we
    -- never yank the cursor out from under someone browsing the tree.
    local tree_win = self._treebuf:get_winid()
    if tree_win > 0 and tree_win ~= vim.api.nvim_get_current_win() then
        self._treebuf:set_cursor_by_id(id)
    end
end

---@param data keystone.symboltree.ItemData
---@param activate boolean
function SymbolTree:_jump_to(data, activate)
    if not data or data.lnum <= 0 then return end
    if not vim.api.nvim_buf_is_valid(self._source_buf) then return end

    local tree_win = vim.api.nvim_get_current_win()
    ui.smart_open_buffer(self._source_buf, data.lnum, data.col)
    if not activate and vim.api.nvim_win_is_valid(tree_win) then
        vim.api.nvim_set_current_win(tree_win)
    end
end

---@param item keystone.tk.TreeBuffer.Item
function SymbolTree:_show_hover(item)
    local data = item.data ---@type keystone.symboltree.ItemData
    local kind = kinds.get(data.kind)
    local lines = {
        "# " .. data.name,
        "",
        "- **Kind**: " .. kind.icon .. " " .. kind.name,
        "- **Line**: " .. data.lnum .. ":" .. (data.col + 1),
        "- **Range**: " .. data.lnum .. "-" .. data.end_lnum,
    }
    if data.detail and data.detail ~= "" then
        table.insert(lines, "- **Detail**: " .. data.detail)
    end

    floatwin.open(table.concat(lines, "\n"), {
        title = "Symbol",
        is_markdown = true,
    })
end

return SymbolTree
