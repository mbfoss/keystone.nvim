local class = require("keystone.utils.class")

---@class keystone.utils.LRU.Node
---@field key any
---@field value any
---@field prev keystone.utils.LRU.Node?
---@field next keystone.utils.LRU.Node?

---@class keystone.utils.LRU
---@field _capacity integer
---@field _count integer
---@field _map table<any, keystone.utils.LRU.Node>
---@field _head keystone.utils.LRU.Node?
---@field _tail keystone.utils.LRU.Node?
---@field _on_evict fun(key:any, value:any)? Called ONLY when _capacity is exceeded.
---@field _on_removed fun(key:any, value:any)? Called for EVERY removal (eviction, delete, clear).
---@field new fun(self:keystone.utils.LRU, capacity:integer, opts?:{on_evict?:fun(key:any, value:any), on_removed?:fun(key:any, value:any)}):keystone.utils.LRU
local LRU = class()

---@param capacity integer
---@param opts? {on_evict?:fun(key:any, value:any), on_removed?:fun(key:any, value:any)}
function LRU:init(capacity, opts)
    assert(type(capacity) == "number" and capacity > 0, "LRU capacity must be a positive integer")
    opts = opts or {}

    self._capacity = capacity
    self._count = 0
    self._map = {}
    self._head = nil
    self._tail = nil
    self._on_evict = opts.on_evict
    self._on_removed = opts.on_removed
end

---@private
function LRU:_remove_links(node)
    if node.prev then node.prev.next = node.next else self._head = node.next end
    if node.next then node.next.prev = node.prev else self._tail = node.prev end
    node.prev = nil
    node.next = nil
end

---@private
function LRU:_insert_front(node)
    node.next = self._head
    node.prev = nil
    if self._head then self._head.prev = node else self._tail = node end
    self._head = node
end

---@private
--- Internal handler for removal logic and callbacks.
function LRU:_delete_node(node, is_eviction)
    self:_remove_links(node)
    self._map[node.key] = nil
    self._count = self._count - 1

    -- 1. Trigger eviction-specific callback
    if is_eviction and self._on_evict then
        self._on_evict(node.key, node.value)
    end

    -- 2. Trigger universal removal callback
    if self._on_removed then
        self._on_removed(node.key, node.value)
    end
end

function LRU:get(key)
    local node = self._map[key]
    if not node then return nil end

    self:_remove_links(node)
    self:_insert_front(node)
    return node.value
end

function LRU:peek(key)
    local node = self._map[key]
    return node and node.value or nil
end

function LRU:put(key, value)
    local node = self._map[key]

    if node then
        node.value = value
        self:_remove_links(node)
        self:_insert_front(node)
        return
    end

    if self._count >= self._capacity then
        local lru_node = self._tail
        if lru_node then
            self:_delete_node(lru_node, true)
        end
    end

    node = { key = key, value = value }
    self._map[key] = node
    self:_insert_front(node)
    self._count = self._count + 1
end

-- Promote a node to the front (most recently used) without changing its value
-- Does nothing if key is not present
function LRU:promote(key)
    local node = self._map[key]
    if not node then return end
    self:_remove_links(node)
    self:_insert_front(node)
end

function LRU:delete(key)
    local node = self._map[key]
    if node then
        self:_delete_node(node, false)
    end
end

function LRU:has(key)
    return self._map[key] ~= nil
end

function LRU:clear()
    if self._on_removed or self._on_evict then
        while self._head do
            self:_delete_node(self._head, false)
        end
    else
        self._map = {}
        self._count = 0
        self._head = nil
        self._tail = nil
    end
end

function LRU:size()
    return self._count
end

---Returns a list of all keys in the cache, ordered from MRU to LRU.
---@return any[]
function LRU:keys()
    local keys = {}
    local current = self._head
    local i = 1

    while current do
        keys[i] = current.key
        current = current.next
        i = i + 1
    end

    return keys
end

function LRU:iter_items()
    local current = self._head
    return function()
        if not current then return nil end
        local key, value = current.key, current.value
        current = current.next
        return key, value
    end
end

return LRU
