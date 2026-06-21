--- The keymap tree. A tree is rebuilt on each trigger press from the live
--- keymaps of the active mode, overlaid with registered group descriptions and
--- builtin generators. Each node is a plain table; the module exposes helpers
--- that operate on it.
local Keys = require("keystone.clue.keys")

local M = {}

---@class keystone.clue.Node
---@field key string                                   single key token (edge from parent)
---@field keys string                                  full normalised sequence from root
---@field parent? keystone.clue.Node
---@field children table<string, keystone.clue.Node>
---@field keymap? table                                live keymap dict, when this node is mapped
---@field desc? string                                 display description
---@field group? boolean                               true when this node is a prefix label
---@field virtual? boolean                             true for generator-produced nodes
---@field expand? fun(): keystone.clue.Item[]          dynamic child generator (marks/registers)

---@class keystone.clue.Item
---@field key string   normalised key token
---@field desc? string

---@param parent? keystone.clue.Node
---@param key? string
---@return keystone.clue.Node
local function _new_node(parent, key)
    return {
        key = key or "",
        keys = (parent and parent.keys or "") .. (key or ""),
        parent = parent,
        children = {},
    }
end

---@return keystone.clue.Node
function M.new_root()
    return _new_node(nil, nil)
end

--- Descend from `root` along a normalised key sequence, optionally creating
--- intermediate nodes.
---@param root keystone.clue.Node
---@param norm_keys string
---@param create boolean
---@return keystone.clue.Node?
local function _descend(root, norm_keys, create)
    local node = root
    for _, tk in ipairs(Keys.split(norm_keys)) do
        local child = node.children[tk]
        if not child then
            if not create then
                return nil
            end
            child = _new_node(node, tk)
            node.children[tk] = child
        end
        node = child
    end
    return node
end

---@param root keystone.clue.Node
---@param norm_keys string
---@return keystone.clue.Node?
function M.find(root, norm_keys)
    return _descend(root, norm_keys, false)
end

---@param km table
---@return boolean
local function _ignored(km)
    if km.desc and km.desc:find("keystone-clue-trigger", 1, true) then
        return true
    end
    local lhs = km.lhs or ""
    if lhs:find("^<Plug>") or lhs:find("^<SNR>") then
        return true
    end
    return false
end

--- Build the tree for `mode` from live keymaps, group descriptions and
--- builtin generators.
---@param mode string mapmode (n/x/o/i/c/...)
---@param clues keystone.clue.Clue[]
---@param builtins { keys: string, expand: fun(): keystone.clue.Item[] }[]
---@return keystone.clue.Node
function M.build(mode, clues, builtins)
    local root = M.new_root()

    -- Live keymaps: global first, then buffer-local so the buffer wins.
    local lists = {
        vim.api.nvim_get_keymap(mode),
        vim.api.nvim_buf_get_keymap(0, mode),
    }
    for _, list in ipairs(lists) do
        for _, km in ipairs(list) do
            if not _ignored(km) then
                local node = _descend(root, Keys.norm(km.lhsraw or km.lhs), true)
                if node then
                    node.keymap = km
                    if km.desc and km.desc ~= "" then
                        node.desc = km.desc
                    end
                end
            end
        end
    end

    -- Overlay registered group labels / description overrides.
    for _, clue in ipairs(clues) do
        local node = _descend(root, clue.keys, true)
        if node then
            if clue.group then
                node.group = true
            end
            if clue.desc and clue.desc ~= "" then
                node.desc = clue.desc
            end
        end
    end

    -- Attach builtin generators (marks/registers).
    for _, b in ipairs(builtins) do
        local node = _descend(root, b.keys, true)
        if node then
            node.expand = b.expand
        end
    end

    return root
end

---@param node keystone.clue.Node
---@return boolean
function M.has_children(node)
    if node.expand then
        return true
    end
    return next(node.children) ~= nil
end

---@param node keystone.clue.Node
---@return string
local function _sort_key(node)
    local is_special = node.key:match("^<") and "1" or "0"
    return is_special .. node.key:lower() .. node.key
end

--- Return the child nodes of `node` (including generated ones), sorted for
--- display. Generated children never override an explicit child of the same key.
---@param node keystone.clue.Node
---@return keystone.clue.Node[]
function M.children(node)
    local out = {} ---@type keystone.clue.Node[]

    if node.expand then
        local ok, items = pcall(node.expand)
        if ok and items then
            for _, item in ipairs(items) do
                if item.key and not node.children[item.key] then
                    local child = _new_node(node, item.key)
                    child.desc = item.desc
                    child.virtual = true
                    out[#out + 1] = child
                end
            end
        end
    end

    for _, child in pairs(node.children) do
        out[#out + 1] = child
    end

    table.sort(out, function(a, b)
        return _sort_key(a) < _sort_key(b)
    end)
    return out
end

return M
