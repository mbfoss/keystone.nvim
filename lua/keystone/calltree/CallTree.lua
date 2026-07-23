local TreeBuffer = require("keystone.tk.TreeBuffer")
local ui         = require("keystone.tk.ui")
local floatwin   = require("keystone.tk.floatwin")
local kinds      = require("keystone.symboltree.kinds")
local calls      = require("keystone.calltree.calls")

--- What one line of the tree holds. `call` is nil for the placeholder rows
--- ("Loading…", "No callers", an error message) which are inert: they never
--- expand and never jump.
---@class keystone.calltree.ItemData
---@field text string? placeholder text, set instead of `call`
---@field call keystone.calltree.Call?
---@field icon string
---@field icon_hl string
---@field state "unloaded"|"loading"|"loaded"
---@field recursive boolean? already present among its own ancestors
---@field is_root boolean?

---@type keystone.symboltree.Kind
local _PLACEHOLDER_KIND = { name = "Placeholder", icon = "󰋗", hl = "Comment" }

--- Full-line highlight for the root of the tree. Linked with `default` so a
--- colorscheme or the user can override it.
local _root_hl = "KeystoneCallTreeRoot"
vim.api.nvim_set_hl(0, _root_hl, { default = true, link = "Title" })

--- Highlight for the direction tag on the root line.
local _direction_hl = "KeystoneCallTreeDirection"
vim.api.nvim_set_hl(0, _direction_hl, { default = true, link = "Special" })

--- How each direction announces itself, named after what the rows under the root
--- actually are rather than after the LSP method.
local _DIRECTIONS = {
    incoming = "CALLERS",
    outgoing = "CALLS",
}

local function _show_help()
    local help_text = { [[
NAVIGATION
==========
`<CR>`    Expand/collapse
`o`       Jump to the symbol, keep focus in the tree
`O`       Jump to the symbol and focus it
`c`       Jump to the call site
`K`       Hover info (kind, location, call sites)

FOLDING
=======
`za`      Toggle expand/collapse
`zc`      Collapse
`zo`      Expand
`zC`      Collapse (recursive)
`zO`      Expand (recursive)

HIERARCHY
=========
The tag on the root line names what the rows below the root are:
`CALLERS` (incoming) or `CALLS` (outgoing).

`<Tab>`   Swap direction (incoming <-> outgoing)
`r`       Re-root the tree on the symbol under the cursor
`<BS>`    Back to the previous root
`R`       Refresh

OTHER
=====
`g?`      Show this help]]
    }

    floatwin.open(table.concat(help_text, "\n"), {
        title = "Call Tree",
        is_markdown = true,
    })
end

---@param uri string
---@return string
local function _display_name(uri)
    local path = vim.uri_to_fname(uri)
    return vim.fn.fnamemodify(path, ":t")
end

---@param data keystone.calltree.ItemData
---@param show_detail boolean
---@param direction keystone.calltree.Direction
---@return string[][] chunks, string[][] virt_chunks, string? line_hl
local function _call_formatter(data, show_detail, direction)
    if not data then return {}, {} end

    local call = data.call
    if not call then
        return { { data.icon, data.icon_hl }, { " " }, { data.text or "", "Comment" } }, {}
    end

    local chunks = {}
    -- Only the root carries the tag: every other row is reached through it, so
    -- one marker says which way the whole tree is being walked.
    if data.is_root then
        chunks[#chunks + 1] = { _DIRECTIONS[direction] .. " ", _direction_hl }
    end
    vim.list_extend(chunks, {
        { data.icon, data.icon_hl },
        { " " },
        { call.name },
    })
    if data.recursive then
        table.insert(chunks, { " ↺", "WarningMsg" })
    end
    if show_detail and call.detail and call.detail ~= "" then
        table.insert(chunks, { " " })
        table.insert(chunks, { call.detail, "Comment" })
    end

    local location = _display_name(call.uri) .. ":" .. (call.call_lnum or call.lnum)
    local virt_chunks = { { " " }, { location, "Comment" } }
    if call.call_count > 1 then
        table.insert(virt_chunks, { " (" .. call.call_count .. ")", "Number" })
    end

    return chunks, virt_chunks, data.is_root and _root_hl or nil
end

---@class keystone.CallTree.Opts
---@field direction keystone.calltree.Direction? which way to walk (default "incoming")
---@field show_detail boolean? show the server-provided detail text (default true)
---@field auto_expand_root boolean? expand the root once resolved (default true)

---@class keystone.CallTree
---@field new fun(self:keystone.CallTree, opts:keystone.CallTree.Opts?):keystone.CallTree
---@field private _treebuf keystone.tk.TreeBuffer
---@field private _provider keystone.calltree.calls.Provider
---@field private _direction keystone.calltree.Direction
---@field private _root keystone.calltree.Call?
---@field private _root_id any?
---@field private _history keystone.calltree.Call[] previous roots, most recent last
---@field private _generation integer invalidates in-flight replies
---@field private _next_id integer
---@field private _opts keystone.CallTree.Opts
---@field private _pending_parent any? parent of the items currently being built
local CallTree = {}
CallTree.__index = CallTree

function CallTree:new(...)
    local obj = setmetatable({}, self)
    if obj.init then obj:init(...) end
    return obj
end

---@param opts keystone.CallTree.Opts?
function CallTree:init(opts)
    self._opts       = opts and vim.deepcopy(opts) or {}
    self._provider   = calls.Provider:new()
    self._direction  = self._opts.direction == "outgoing" and "outgoing" or "incoming"
    self._root       = nil
    self._root_id    = nil
    self._history    = {}
    self._generation = 0
    self._next_id    = 0

    self:_setup_tree()
end

function CallTree:_setup_tree()
    assert(not self._treebuf)

    self._treebuf = TreeBuffer.new({
        filetype  = "keystone-calltree",
        formatter = function(_, data)
            return _call_formatter(data, self._opts.show_detail ~= false, self._direction)
        end,
    })

    self._treebuf:subscribe({
        -- Only fires for rows that cannot expand, i.e. the placeholders and
        -- leaves whose call list came back empty.
        on_selection = function(_, data)
            if data and data.call then self:_jump_to(data.call, false) end
        end,
        on_toggle = function(id, _, expanded)
            if expanded then self:_ensure_children(id) end
        end,
    })
end

---@return any
function CallTree:_new_id()
    self._next_id = self._next_id + 1
    return self._next_id
end

---@return integer bufnr
function CallTree:create_buffer()
    local bufnr, created = self._treebuf:create_buffer(function()
        self:_on_buffer_deleted()
    end)

    if not created then return bufnr end

    ---@param fn fun(call:keystone.calltree.Call)
    local function with_call(fn)
        local item = self._treebuf:get_cursor_item()
        local data = item and item.data ---@type keystone.calltree.ItemData?
        if data and data.call then fn(data.call) end
    end

    local keymaps = {
        -- Navigation
        ["o"] = {
            function() with_call(function(call) self:_jump_to(call, false) end) end,
            "Jump to symbol (keep focus)",
        },
        ["O"] = {
            function() with_call(function(call) self:_jump_to(call, true) end) end,
            "Jump to symbol",
        },
        ["c"] = {
            function() with_call(function(call) self:_jump_to_call_site(call) end) end,
            "Jump to call site",
        },
        ["K"] = {
            function() with_call(function(call) self:_show_hover(call) end) end,
            "Show symbol info",
        },
        -- Hierarchy
        ["<Tab>"] = {
            function() self:swap_direction() end,
            "Swap call direction",
        },
        ["r"] = {
            function() with_call(function(call) self:set_root(call, true) end) end,
            "Re-root on symbol",
        },
        ["<BS>"] = {
            function() self:pop_root() end,
            "Back to previous root",
        },
        ["R"] = {
            function() self:refresh() end,
            "Refresh",
        },
        -- Other
        ["g?"] = {
            function() _show_help() end,
            "Show Help",
        },
    }

    assert(bufnr > 0)
    for key, map in pairs(keymaps) do
        vim.api.nvim_buf_set_keymap(bufnr, "n", key, "", { callback = map[1], desc = map[2] })
    end

    if not self._root then
        self:_show_placeholder("No call hierarchy")
    end

    return bufnr
end

function CallTree:get_bufnr()
    return self._treebuf:get_bufnr()
end

---@return keystone.calltree.Direction
function CallTree:get_direction()
    return self._direction
end

function CallTree:_on_buffer_deleted()
    -- Invalidate replies still in flight: they would render into a buffer that
    -- no longer exists.
    self._generation = self._generation + 1
    self._root = nil
    self._root_id = nil
    self._history = {}
end

---@param text string
function CallTree:_show_placeholder(text)
    if self._treebuf:get_bufnr() == -1 then return end
    self._treebuf:clear_items()
    self._root_id = nil
    self._treebuf:add_item(nil, {
        id = self:_new_id(),
        data = { text = text, icon = _PLACEHOLDER_KIND.icon, icon_hl = _PLACEHOLDER_KIND.hl, state = "loaded" },
    })
end

--- Resolve the symbol at the cursor of `winid` and make it the root.
---@param bufnr integer
---@param winid integer
---@param direction keystone.calltree.Direction? applied before resolving
function CallTree:show_from_cursor(bufnr, winid, direction)
    if direction then self._direction = direction end

    self._generation = self._generation + 1
    local generation = self._generation

    self:_show_placeholder("Resolving symbol…")

    self._provider:prepare(bufnr, winid, {
        on_root = function(root)
            if generation ~= self._generation then return end
            self:set_root(root, false)
        end,
        on_unavailable = function(reason)
            if generation ~= self._generation then return end
            self._root = nil
            self:_show_placeholder(reason)
        end,
    })
end

--- Rebuild the tree around `root`. Any in-flight reply is dropped.
---@param root keystone.calltree.Call
---@param remember boolean? push the current root onto the back-stack
function CallTree:set_root(root, remember)
    if remember and self._root and calls.identity(self._root) ~= calls.identity(root) then
        self._history[#self._history + 1] = self._root
    end

    self._generation = self._generation + 1
    self._root = root
    self:_populate()
end

--- Return to the root we came from, if any.
function CallTree:pop_root()
    local previous = table.remove(self._history)
    if not previous then return end
    self:set_root(previous, false)
end

--- Walk the hierarchy the other way, keeping the same root.
---@param direction keystone.calltree.Direction
function CallTree:set_direction(direction)
    if direction == self._direction then return end
    self._direction = direction
    if self._root then
        self._generation = self._generation + 1
        self:_populate()
    end
end

function CallTree:swap_direction()
    self:set_direction(self._direction == "incoming" and "outgoing" or "incoming")
end

--- Discard every loaded call list and start over from the current root.
function CallTree:refresh()
    if not self._root then return end
    self._generation = self._generation + 1
    self:_populate()
end

function CallTree:_populate()
    if self._treebuf:get_bufnr() == -1 then return end
    local root = self._root
    if not root then
        self:_show_placeholder("No call hierarchy")
        return
    end

    self._treebuf:clear_items()
    self._root_id = self:_new_id()
    self._treebuf:add_item(nil, self:_make_item(self._root_id, root, true))

    if self._opts.auto_expand_root ~= false then
        self._treebuf:expand(self._root_id)
    end
end

---@param id any
---@param call keystone.calltree.Call
---@param is_root boolean
---@return keystone.tk.TreeBuffer.ItemDef
function CallTree:_make_item(id, call, is_root)
    local kind = kinds.get(call.kind)
    local recursive = not is_root and self:_is_recursive(call)

    ---@type keystone.calltree.ItemData
    local data = {
        call      = call,
        icon      = kind.icon,
        icon_hl   = kind.hl,
        -- A node that repeats one of its own ancestors would expand forever, so
        -- it is shown but left as a leaf; `r` still re-roots on it.
        state     = recursive and "loaded" or "unloaded",
        recursive = recursive or nil,
        is_root   = is_root or nil,
    }

    return {
        id         = id,
        data       = data,
        expandable = not recursive,
        expanded   = false,
    }
end

--- Whether `call` already appears among the ancestors of the item currently
--- being built. Only meaningful while `_pending_parent` is set.
---@param call keystone.calltree.Call
---@return boolean
function CallTree:_is_recursive(call)
    local identity = calls.identity(call)
    local id = self._pending_parent
    while id ~= nil do
        local data = self._treebuf:get_item_data(id) ---@type keystone.calltree.ItemData?
        if data and data.call and calls.identity(data.call) == identity then
            return true
        end
        id = self._treebuf:get_parent_id(id)
    end
    return false
end

---@param parent_id any
---@param text string
function CallTree:_set_placeholder_child(parent_id, text)
    self._treebuf:set_children(parent_id, {
        {
            id   = self:_new_id(),
            data = { text = text, icon = _PLACEHOLDER_KIND.icon, icon_hl = _PLACEHOLDER_KIND.hl, state = "loaded" },
            expandable = false,
        },
    })
end

--- Fetch the calls for `id` the first time it is expanded.
---@param id any
function CallTree:_ensure_children(id)
    local data = self._treebuf:get_item_data(id) ---@type keystone.calltree.ItemData?
    if not data or not data.call or data.state ~= "unloaded" then return end

    data.state = "loading"
    self:_set_placeholder_child(id, "Loading…")

    local generation = self._generation
    local direction  = self._direction

    ---@return boolean
    local function stale()
        return generation ~= self._generation
            or self._treebuf:get_bufnr() == -1
            or not self._treebuf:have_item(id)
    end

    self._provider:calls(data.call, direction, {
        on_calls = function(result)
            if stale() then return end
            data.state = "loaded"

            if #result == 0 then
                self:_set_placeholder_child(id,
                    direction == "incoming" and "No callers" or "No calls")
                return
            end

            self._pending_parent = id
            local children = {}
            for _, call in ipairs(result) do
                children[#children + 1] = self:_make_item(self:_new_id(), call, false)
            end
            self._pending_parent = nil

            self._treebuf:set_children(id, children)
        end,
        on_unavailable = function(reason)
            if stale() then return end
            -- Leave the node unloaded so expanding it again retries.
            data.state = "unloaded"
            self:_set_placeholder_child(id, reason)
        end,
    })
end

--- Load the document `uri` names into a buffer, without displaying it.
---@param uri string
---@return integer? bufnr
local function _uri_bufnr(uri)
    local bufnr = vim.uri_to_bufnr(uri)
    if not vim.api.nvim_buf_is_valid(bufnr) then return nil end
    if not vim.api.nvim_buf_is_loaded(bufnr) then vim.fn.bufload(bufnr) end
    return bufnr
end

---@param uri string
---@param lnum integer
---@param col integer
---@param activate boolean focus the window we jumped into
function CallTree:_open(uri, lnum, col, activate)
    local bufnr = _uri_bufnr(uri)
    if not bufnr then return end

    local tree_win = vim.api.nvim_get_current_win()
    ui.smart_open_buffer(bufnr, lnum, col)
    if not activate and vim.api.nvim_win_is_valid(tree_win) then
        vim.api.nvim_set_current_win(tree_win)
    end
end

---@param call keystone.calltree.Call
---@param activate boolean
function CallTree:_jump_to(call, activate)
    self:_open(call.uri, call.lnum, call.col, activate)
end

--- Jump to where the call itself is written, which for an outgoing call is in a
--- different document than the symbol it names.
---@param call keystone.calltree.Call
function CallTree:_jump_to_call_site(call)
    if not call.call_uri or not call.call_lnum then
        self:_jump_to(call, false)
        return
    end
    self:_open(call.call_uri, call.call_lnum, call.call_col or 0, false)
end

---@param call keystone.calltree.Call
function CallTree:_show_hover(call)
    local kind = kinds.get(call.kind)
    local lines = {
        "# " .. call.name,
        "",
        "- **Kind**: " .. kind.icon .. " " .. kind.name,
        "- **File**: " .. vim.fn.fnamemodify(vim.uri_to_fname(call.uri), ":~:."),
        "- **Line**: " .. call.lnum .. ":" .. (call.col + 1),
    }
    if call.detail and call.detail ~= "" then
        table.insert(lines, "- **Detail**: " .. call.detail)
    end
    if call.call_lnum then
        table.insert(lines, "- **Call site**: "
            .. vim.fn.fnamemodify(vim.uri_to_fname(call.call_uri or call.uri), ":~:.")
            .. ":" .. call.call_lnum)
        table.insert(lines, "- **Call sites**: " .. call.call_count)
    end

    floatwin.open(table.concat(lines, "\n"), {
        title = "Call",
        is_markdown = true,
    })
end

return CallTree
