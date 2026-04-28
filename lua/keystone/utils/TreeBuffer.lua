local class = require('keystone.utils.class')
local ScratchBuffer = require('keystone.utils.ScratchBuffer')
local Tree = require("keystone.utils.Tree")

---@class keystone.TreeBuffer.Item
---@field id any
---@field data any
---@field expandable boolean
---@field expanded boolean

---@class keystone.TreeBuffer.ItemDef
---@field id any
---@field data any
---@field expandable boolean?
---@field expanded boolean|nil

---@class keystone.TreeBuffer.ItemUpdate : keystone.TreeBuffer.ItemDef
---@field keep_children boolean

---@class keystone.TreeBuffer.ItemData
---@field userdata any
---@field expandable boolean?
---@field expanded boolean|nil

---@class keystone.TreeBuffer.Tracker
---@field on_selection? fun(id:any,data:any)
---@field on_toggle? fun(id:any,data:any,expanded:boolean)

---@class keystone.TreeBuffer.VirtText
---@field text string
---@field highlight string

---@alias keystone.TreeBuffer.FormatterFn fun(id:any, data:any,expanded:boolean):string[][],string[][]
---@
---@class keystone.TreeBuffer.Opts
---@field filetype string?
---@field formatter keystone.TreeBuffer.FormatterFn
---@field expand_char string?
---@field collapse_char string?
---@field indent_string string?

---@class keystone.TreeBuffer.Tracker : keystone.Tracker
---@field on_selection? fun(id:any,data:any)
---@field on_toggle? fun(id:any,data:any,expanded:boolean)

local _ns_id = vim.api.nvim_create_namespace('keystoneTreeBuffer')

---@class keystone.TreeBuffer:keystone.ScratchBuffer
---@field new fun(self: keystone.TreeBuffer,opts:keystone.TreeBuffer.Opts): keystone.TreeBuffer
local TreeBuffer = class(ScratchBuffer)

---@param item keystone.TreeBuffer.ItemDef
---@return keystone.TreeBuffer.ItemData
local function _itemdef_to_itemdata(item)
    return {
        userdata = item.data,
        expandable = item.expandable,
        expanded = item.expanded,
    }
end


---@param tree keystone.utils.Tree
---@param starting_id any|nil  -- nil = whole tree
---@return keystone.utils.Tree.FlatNode[]
local function _flatten(tree, starting_id)
    local out = {}
    local function handler(id, data, depth)
        out[#out + 1] = {
            id = id,
            data = data,
            depth = depth,
        }
        return data.expanded
    end
    if starting_id == nil then
        tree:walk_tree(handler)
    else
        tree:walk_node(starting_id, handler)
    end
    return out
end

---@param tree keystone.utils.Tree
---@param starting_id any|nil  -- nil = whole tree
---@return number
local function _tree_size(tree, starting_id)
    local size = 0
    local function handler(id, data, depth)
        size = size + 1
        return data.expanded
    end
    if starting_id == nil then
        tree:walk_tree(handler)
    else
        tree:walk_node(starting_id, handler)
    end
    return size
end

---@param opts keystone.TreeBuffer.Opts
function TreeBuffer:init(opts)
    ScratchBuffer.init(self, {
        bo = {
            buftype = "nofile",
            bufhidden = "wipe",
            filetype = opts.filetype or "keystone-tree",
            modifiable = false,
            swapfile = false,
            undolevels = -1,
            buflisted = false,
            modeline = false,
            spelloptions = "noplainbuffer",
        }
    })
    ---@type keystone.TreeBuffer.FormatterFn
    self._formatter = opts.formatter
    self._expand_char = opts.expand_char or "▶"
    self._collapse_char = opts.collapse_char or "▼"
    self._indent_string = opts.indent_string or "  "
    self._expand_padding = string.rep(" ", vim.fn.strdisplaywidth(self._expand_char)) .. " "
    self._indent_cache = {}
    for i = 0, 20 do
        self._indent_cache[i] = string.rep(opts.indent_string or "  ", i)
    end

    self._tree = Tree:new()

    ---@type number[]
    self._flat_ids = {}
    ---@type table<any, number>
    self._id_to_idx = {}

    self:add_tracker({
        on_loaded = function()
            self:_setup_tree_buf()
        end
    })
end

function TreeBuffer:destroy()
    ScratchBuffer.destroy(self)
end

---@private
function TreeBuffer:_setup_tree_buf()
    local buf = self:get_buf()
    if buf == -1 then return end

    self:_full_render()

    ---@return keystone.TreeBuffer.ItemData?
    local callbacks = {
        on_enter = function()
            ---@type any,keystone.TreeBuffer.ItemData?
            local id, data = self:_get_cur_item()
            if id and data then
                if data.expandable or self._tree:have_children(id) then
                    self:toggle_expand(id)
                else
                    self._trackers:invoke("on_selection", id, data.userdata)
                end
            end
        end,
        toggle = function()
            local id, data = self:_get_cur_item()
            if id and data and self._tree:have_children(id) then
                self:toggle_expand(id)
            end
        end,
        expand = function()
            local id, data = self:_get_cur_item()
            if id and data and self._tree:have_children(id) then
                self:expand(id)
            end
        end,

        collapse = function()
            local id, data = self:_get_cur_item()
            if id and data and self._tree:have_children(id) then
                self:collapse(id)
            end
        end,

        expand_recursive = function()
            local id = self:_get_cur_item()
            if id then self:expand_all(id) end
        end,

        collapse_recursive = function()
            local id = self:_get_cur_item()
            if id then self:collapse_all(id) end
        end,
    }

    local keymaps = {
        ["<CR>"] = { callbacks.on_enter, "Expand/collapse" },
        ["<2-LeftMouse>"] = { callbacks.on_enter, "Expand/collapse" },
        ["zo"] = { callbacks.expand, "Expand node under cursor" },
        ["zc"] = { callbacks.collapse, "Collapse node under cursor" },
        ["za"] = { callbacks.toggle, "Toggle node under cursor" },
        ["zO"] = { callbacks.expand_recursive, "Expand all nodes under cursor" },
        ["zC"] = { callbacks.collapse_recursive, "Collapse all nodes under cursor" },
    }
    for key, map in pairs(keymaps) do
        self:set_keymap("n", key, map[1], { desc = map[2] })
    end
end

---@param callbacks keystone.TreeBuffer.Tracker
---@return keystone.TrackerRef
function TreeBuffer:add_tracker(callbacks)
    return self._trackers:add_tracker(callbacks)
end

---@private
---@param flatnode keystone.utils.Tree.FlatNode
---@param row number The buffer row this node will occupy
---@return string line, table hl_calls, table extmark_data
function TreeBuffer:_render_node(flatnode, row)
    ---@type any,keystone.TreeBuffer.ItemData, number
    local item_id, item, depth = flatnode.id, flatnode.data, flatnode.depth
    local hl_calls = {}
    local extmark_data = {}
    local icon = ""
    if item_id and (item.expandable or self._tree:have_children(item_id)) then
        icon = item.expanded and self._collapse_char or self._expand_char
    end

    local indent = self._indent_cache[depth] or string.rep(self._indent_string, depth)
    local prefix = icon ~= "" and (indent .. icon .. " ") or (indent .. self._expand_padding)
    local text_chunks, virt = self._formatter(item_id, item.userdata, item.expanded)

    local current_line = prefix
    local col = #prefix

    for i = 1, #text_chunks do
        local chunk = text_chunks[i]
        local txt, hl = chunk[1], chunk[2]
        txt = (txt or ""):gsub("\n", "↵")
        local len = #txt
        if len > 0 then
            if hl then
                table.insert(hl_calls, { hl = hl, row = row, s_col = col, e_col = col + len })
            end
            current_line = current_line .. txt
            col = col + len
        end
    end
    if virt and #virt > 0 then
        table.insert(extmark_data, { row, 0, { virt_text = virt, hl_mode = "combine" } })
    end

    return current_line, hl_calls, extmark_data
end

---@private
function TreeBuffer:_full_render()
    local buf = self:get_buf()
    if buf <= 0 then return end
    if not vim.api.nvim_buf_is_loaded(buf) then return end

    local buffer_lines = {}
    local extmarks_data = {}
    local hl_calls = {}
    self._flat_ids = {}
    self._id_to_idx = {}

    local flat = _flatten(self._tree, nil)

    for _, flatnode in ipairs(flat) do
        local row = #buffer_lines
        local line, n_hls, n_exts = self:_render_node(flatnode, row)

        table.insert(buffer_lines, line)
        table.insert(self._flat_ids, flatnode.id)
        self._id_to_idx[flatnode.id] = #self._flat_ids
        for _, h in ipairs(n_hls) do table.insert(hl_calls, h) end
        for _, e in ipairs(n_exts) do table.insert(extmarks_data, e) end
    end

    vim.api.nvim_buf_clear_namespace(buf, _ns_id, 0, -1)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, buffer_lines)
    vim.bo[buf].modifiable = false

    self:_apply_metadata(buf, hl_calls, extmarks_data)
end

---@private
---@param start_idx number
---@param old_size number
---@param new_flat keystone.utils.Tree.FlatNode[]
function TreeBuffer:_render_range(start_idx, old_size, new_flat)
    local buf = self:get_buf()
    if buf <= 0 then return end
    if not vim.api.nvim_buf_is_loaded(buf) then return end

    local new_lines, new_ids = {}, {}
    local range_hls, range_exts = {}, {}
    local start_row = start_idx - 1
    for i, flatnode in ipairs(new_flat) do
        local row = start_row + i - 1
        local line, hls, exts = self:_render_node(flatnode, row)
        table.insert(new_lines, line)
        table.insert(new_ids, flatnode.id)
        for _, h in ipairs(hls) do table.insert(range_hls, h) end
        for _, e in ipairs(exts) do table.insert(range_exts, e) end
    end

    vim.api.nvim_buf_clear_namespace(buf, _ns_id, start_row, start_row + old_size)

    local end_row = start_row + old_size
    if old_size == 0 and vim.api.nvim_buf_line_count(buf) == 1 then
        if vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "" then
            end_row = -1
        end
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, start_row, end_row, false, new_lines)
    vim.bo[buf].modifiable = false

    for i = 0, old_size - 1 do
        local old_id = self._flat_ids[start_idx + i]
        if old_id ~= nil then
            self._id_to_idx[old_id] = nil
        end
    end
    for _ = 1, old_size do
        table.remove(self._flat_ids, start_idx)
    end
    for i, id in ipairs(new_ids) do
        table.insert(self._flat_ids, start_idx + i - 1, id)
    end

    for i = start_idx, #self._flat_ids do
        local id = self._flat_ids[i]
        if id ~= nil then
            self._id_to_idx[id] = i
        end
    end

    self:_apply_metadata(buf, range_hls, range_exts)

    self:_fix_viewport()
end

---@private
function TreeBuffer:_fix_viewport()
    local winid = self:_get_winid()
    local buf = self:get_buf()
    if winid > 0 and buf > 0 then
        local line_count = vim.api.nvim_buf_line_count(buf)
        local win_height = vim.api.nvim_win_get_height(winid)
        vim.api.nvim_win_call(winid, function()
            local view = vim.fn.winsaveview()
            if (view.topline + win_height - 1) > line_count then
                local new_topline = math.max(1, line_count - win_height + 1)
                if new_topline ~= view.topline then
                    vim.fn.winrestview({ topline = new_topline })
                end
            end
        end)
    end
end

---@private
---@param id number
---@param data keystone.TreeBuffer.ItemData?
function TreeBuffer:_render_line(id, data)
    if not data then data = self:_get_data(id) end
    assert(data, "failed to render line, invalid data")
    local idx = self._id_to_idx[id]
    if idx then
        local depth = self._tree:get_depth(id)
        self:_render_range(idx, 1, { { id = id, data = data, depth = depth } })
    end
end

---@private
function TreeBuffer:_apply_metadata(buf, hl_calls, extmarks)
    for _, h in ipairs(hl_calls) do
        vim.api.nvim_buf_set_extmark(buf, _ns_id, h.row, h.s_col, {
            end_col = h.e_col,
            hl_group = h.hl,
        })
    end
    for _, d in ipairs(extmarks) do
        vim.api.nvim_buf_set_extmark(buf, _ns_id, d[1], d[2], d[3])
    end
end

---@param winid number The window handle to check.
---@return keystone.TreeBuffer.Item[]
function TreeBuffer:get_visible_items(winid)
    if not winid or not vim.api.nvim_win_is_valid(winid) then return {} end
    if vim.api.nvim_win_get_buf(winid) ~= self:get_buf() then return {} end
    local start_line = vim.fn.line("w0", winid)
    local end_line = vim.fn.line("w$", winid)

    local visible_items = {}
    for i = start_line, end_line do
        local id = self._flat_ids[i]
        if id and type(id) ~= "table" then
            local base_data = self:_get_data(id)
            if base_data then
                table.insert(visible_items, {
                    id = id,
                    data = base_data.userdata,
                    expandable = base_data.expandable,
                    expanded = base_data.expanded
                })
            end
        end
    end

    return visible_items
end

function TreeBuffer:clear_items()
    self._tree = Tree:new()
    self._flat_ids = {}
    self._id_to_idx = {}
    self:_full_render()
end

---@private
---@return keystone.TreeBuffer.ItemData
function TreeBuffer:_get_data(id)
    return self._tree:get_data(id)
end

---@return keystone.TreeBuffer.Item?
function TreeBuffer:get_item(id)
    local basedata = self:_get_data(id)
    if not basedata then return nil end
    return { id = id, data = basedata.userdata, expandable = basedata.expandable, expanded = basedata.expanded }
end

---@return any?
function TreeBuffer:get_item_data(id)
    local basedata = self:_get_data(id)
    return basedata and basedata.userdata or nil
end

---@return keystone.TreeBuffer.Item[]
function TreeBuffer:get_items()
    local items = {}
    for _, treeitem in ipairs(self._tree:get_items()) do
        ---@type keystone.TreeBuffer.ItemData
        local data = treeitem.data
        ---@type keystone.TreeBuffer.Item
        local item = {
            id = treeitem.id,
            data = data.userdata,
            expandable = data.expandable,
            expanded = data.expanded,
        }
        table.insert(items, item)
    end
    return items
end

---@param id any
---@return any|nil parent_id
function TreeBuffer:get_parent_id(id)
    return self._tree:get_parent_id(id)
end

---@return keystone.TreeBuffer.Item?
function TreeBuffer:get_parent_item(id)
    local par_id = self._tree:get_parent_id(id)
    if not par_id then return nil end

    ---@type keystone.TreeBuffer.ItemData
    local itemdata = self._tree:get_data(par_id)
    if not itemdata then return nil end

    return { id = par_id, data = itemdata.userdata, expandable = itemdata.expandable, expanded = itemdata.expanded }
end

---@private
---@return number
function TreeBuffer:_get_winid()
    local buf = self:get_buf()
    if buf <= 0 then return -1 end
    local winid
    if vim.api.nvim_get_current_buf() == buf then
        winid = vim.api.nvim_get_current_win()
    else
        winid = vim.fn.bufwinid(buf)
    end
    return winid
end

---@return number window id, -1 if invalid
function TreeBuffer:get_winid()
    return self:_get_winid()
end

---@private
---@return any, keystone.TreeBuffer.ItemData?
function TreeBuffer:_get_cur_item()
    local winid = self:_get_winid()
    if winid <= 0 then return end
    local cursor = vim.api.nvim_win_get_cursor(winid)
    if not cursor then return end
    local id = self._flat_ids[cursor[1]]
    if not id then return end
    return id, self:_get_data(id)
end

---@return keystone.TreeBuffer.Item?
function TreeBuffer:get_cursor_item()
    local id, itemdata = self:_get_cur_item()
    if not id or not itemdata then return nil end
    return { id = id, data = itemdata.userdata, expandable = itemdata.expandable, expanded = itemdata.expanded }
end

---@return boolean
function TreeBuffer:set_cursor_by_id(id)
    local winid = self:_get_winid()
    if winid <= 0 then return false end
    local idx = self._id_to_idx[id]
    if idx then
        local ok, _ = pcall(vim.api.nvim_win_set_cursor, winid, { idx, 0 })
        return ok
    end
    return false
end

---@param parent_id any -- null for root
---@param children keystone.TreeBuffer.ItemDef[]
---@return boolean
function TreeBuffer:set_children(parent_id, children)
    if parent_id and not self._tree:have_item(parent_id) then return false end
    local baseitems = {}
    for _, c in ipairs(children) do
        table.insert(baseitems, { id = c.id, data = _itemdef_to_itemdata(c) })
    end
    local old_visible_size = _tree_size(self._tree, parent_id)
    self._tree:set_children(parent_id, baseitems)

    local buf = self:get_buf()
    if buf > 0 then
        if parent_id == nil then
            local new_flat = _flatten(self._tree, nil)
            local current_tree_size = #self._flat_ids
            if current_tree_size < 0 then current_tree_size = 0 end
            self:_render_range(1, current_tree_size, new_flat)
        else
            local parent_data = self._tree:get_data(parent_id)
            assert(parent_data)
            local parent_idx = self._id_to_idx[parent_id]
            if parent_idx then
                local base_depth = self._tree:get_depth(parent_id)
                local new_flat = _flatten(self._tree, parent_id)
                for _, node in ipairs(new_flat) do
                    node.depth = base_depth + node.depth
                end
                self:_render_range(parent_idx, old_visible_size, new_flat)
            end
        end
    end
    return true
end

---@param id any The ID of the parent node whose children should be removed.
function TreeBuffer:remove_children(id)
    self:set_children(id, {})
end

function TreeBuffer:toggle_expand(id)
    local data = self:_get_data(id)
    if data then
        if not data.expanded then
            self:expand(id)
        else
            self:collapse(id)
        end
    end
end

function TreeBuffer:expand(id)
    local data = self:_get_data(id)
    if not data or data.expanded or not (data.expandable or self._tree:have_children(id)) then return end

    local idx = self._id_to_idx[id]
    data.expanded = true

    if idx then
        local base_depth = self._tree:get_depth(id)
        local new_subtree_flat = _flatten(self._tree, id)
        for _, node in ipairs(new_subtree_flat) do
            node.depth = base_depth + node.depth
        end
        self:_render_range(idx, 1, new_subtree_flat)
    end

    self._trackers:invoke("on_toggle", id, data.userdata, true)
end

function TreeBuffer:collapse(id)
    local data = self:_get_data(id)
    if not data or not data.expanded then return end
    local current_visible_size = _tree_size(self._tree, id)
    data.expanded = false
    local idx = self._id_to_idx[id]
    if idx then
        local depth = self._tree:get_depth(id)
        local parent_flat = { id = id, data = data, depth = depth }
        self:_render_range(idx, current_visible_size, { parent_flat })
    end

    self._trackers:invoke("on_toggle", id, data.userdata, false)
end

function TreeBuffer:expand_all(id)
    local data = self:_get_data(id)
    if not data then return end
    if not data.expanded and (data.expandable or self._tree:have_children(id)) then
        self:expand(id)
    end
    local children = self._tree:get_children(id)
    for _, child in ipairs(children) do
        self:expand_all(child.id)
    end
end

function TreeBuffer:collapse_all(id)
    local data = self:_get_data(id)
    if not data then return end
    if data.expanded then
        self:collapse(id)
    end
    local children = self._tree:get_children(id)
    for _, child in ipairs(children) do
        self:collapse_all(child.id)
    end
end

---@param parent_id any -- null to add to root
---@param item keystone.TreeBuffer.ItemDef
---@return boolean
function TreeBuffer:add_item(parent_id, item)
    if parent_id and not self._tree:have_item(parent_id) then return false end
    local item_data = _itemdef_to_itemdata(item)
    self._tree:add_item(parent_id, item.id, item_data)

    local buf = self:get_buf()
    if buf > 0 then
        if parent_id == nil then
            local insert_idx = #self._flat_ids + 1
            local node = {
                id = item.id,
                data = item_data,
                depth = 0
            }
            self:_render_range(insert_idx, 0, { node })
        else
            local parent_idx = self._id_to_idx[parent_id]
            if parent_idx then
                local parent_data = self._tree:get_data(parent_id)
                self:_render_line(parent_id, parent_data)
                if parent_data and parent_data.expanded then
                    local current_subtree_size = _tree_size(self._tree, parent_id)
                    local insert_idx = parent_idx + current_subtree_size - 1
                    local node = {
                        id = item.id,
                        data = item_data,
                        depth = self._tree:get_depth(item.id)
                    }
                    self:_render_range(insert_idx, 0, { node })
                end
            end
        end
    end
    return true
end

---@param reference_id any The ID of the existing node to position relative to.
---@param item keystone.TreeBuffer.ItemDef The new item to add.
---@param before boolean true to insert before sibling, false to insert after.
---@return boolean
function TreeBuffer:add_sibling(reference_id, item, before)
    if reference_id and not self._tree:have_item(reference_id) then return false end
    local item_data = _itemdef_to_itemdata(item)
    self._tree:add_sibling(reference_id, item.id, item_data, before)

    local buf = self:get_buf()
    if buf <= 0 then return true end
    local ref_idx = self._id_to_idx[reference_id]
    if ref_idx then
        local insert_idx

        if before then
            insert_idx = ref_idx
        else
            local ref_visible_size = _tree_size(self._tree, reference_id)
            insert_idx = ref_idx + ref_visible_size
        end

        local node = {
            id = item.id,
            data = item_data,
            depth = self._tree:get_depth(item.id)
        }
        self:_render_range(insert_idx, 0, { node })
    end

    return true
end

---@return keystone.TreeBuffer.Item[]
function TreeBuffer:get_roots()
    local items = {}
    local tree_items = self._tree:get_roots()

    for _, treeitem in ipairs(tree_items) do
        ---@type keystone.TreeBuffer.ItemData
        local data = treeitem.data
        ---@type keystone.TreeBuffer.Item
        local item = {
            id = treeitem.id,
            data = data.userdata,
            expandable = data.expandable,
            expanded = data.expanded
        }
        table.insert(items, item)
    end
    return items
end

function TreeBuffer:get_children_ids(parent_id)
    return self._tree:get_children_ids(parent_id)
end

---@return keystone.TreeBuffer.Item[]
function TreeBuffer:get_children(parent_id)
    local items = {}
    local tree_items = self._tree:get_children(parent_id)

    for _, treeitem in ipairs(tree_items) do
        ---@type keystone.TreeBuffer.ItemData
        local data = treeitem.data
        ---@type keystone.TreeBuffer.Item
        local item = {
            id = treeitem.id,
            data = data.userdata,
            expandable = data.expandable,
            expanded = data.expanded
        }
        table.insert(items, item)
    end
    return items
end

---@param id any
---@return boolean
function TreeBuffer:have_item(id)
    return self._tree:have_item(id)
end

---@param id any
---@return boolean
function TreeBuffer:have_children(id)
    return self._tree:have_children(id)
end

---@param id any The ID of the item to remove.
---@return boolean success
function TreeBuffer:remove_item(id)
    if not self._tree:have_item(id) then return false end
    local parent_id = self._tree:get_parent_id(id)
    local visible_size = _tree_size(self._tree, id)
    self._tree:remove_item(id)
    local idx = self._id_to_idx[id]
    if idx then
        self:_render_range(idx, visible_size, {})
        if parent_id ~= nil then
            self:_render_line(parent_id)
        end
    end

    return true
end

---@param id any
---@param data any -- user data
---@return boolean
function TreeBuffer:set_item_data(id, data)
    ---@type keystone.TreeBuffer.ItemData
    local base_data = self._tree:get_data(id)
    if not base_data then return false end
    base_data.userdata = data
    self:_render_line(id, base_data)
    return true
end

---@param id any
---@param expandable boolean
---@return boolean
function TreeBuffer:set_item_expandable(id, expandable)
    ---@type keystone.TreeBuffer.ItemData
    local base_data = self._tree:get_data(id)
    if not base_data then return false end
    if expandable ~= base_data.expandable then
        base_data.expandable = expandable
        self:_render_line(id, base_data)
    end
    return true
end

---@param id any
---@return boolean
function TreeBuffer:refresh_item(id)
    local data = self:_get_data(id)
    if not data then return false end
    self:_render_line(id, data)
    return true
end

return TreeBuffer
