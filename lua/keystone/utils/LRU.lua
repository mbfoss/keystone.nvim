local class = require("keystone.utils.class")

---@class keystone.utils.LRU.Node
---@field key any
---@field value any
---@field prev keystone.utils.LRU.Node?
---@field next keystone.utils.LRU.Node?

---@class keystone.utils.LRU
---@field capacity integer
---@field count integer
---@field map table<any, keystone.utils.LRU.Node>
---@field head keystone.utils.LRU.Node?
---@field tail keystone.utils.LRU.Node?
---@field on_evict fun(key:any, value:any)? Called ONLY when capacity is exceeded.
---@field on_removed fun(key:any, value:any)? Called for EVERY removal (eviction, delete, clear).
---@field new fun(self:keystone.utils.LRU, capacity:integer, opts?:{on_evict?:fun(key:any, value:any), on_removed?:fun(key:any, value:any)}):keystone.utils.LRU
local LRU = class()

---@param capacity integer
---@param opts? {on_evict?:fun(key:any, value:any), on_removed?:fun(key:any, value:any)}
function LRU:init(capacity, opts)
    assert(type(capacity) == "number" and capacity > 0, "LRU capacity must be a positive integer")
    opts = opts or {}

    self.capacity = capacity
    self.count = 0
    self.map = {}
    self.head = nil
    self.tail = nil
    self.on_evict = opts.on_evict
    self.on_removed = opts.on_removed
end

---@private
function LRU:_remove_links(node)
    if node.prev then node.prev.next = node.next else self.head = node.next end
    if node.next then node.next.prev = node.prev else self.tail = node.prev end
    node.prev = nil
    node.next = nil
end

---@private
function LRU:_insert_front(node)
    node.next = self.head
    node.prev = nil
    if self.head then self.head.prev = node else self.tail = node end
    self.head = node
end

---@private
--- Internal handler for removal logic and callbacks.
function LRU:_delete_node(node, is_eviction)
    self:_remove_links(node)
    self.map[node.key] = nil
    self.count = self.count - 1

    -- 1. Trigger eviction-specific callback
    if is_eviction and self.on_evict then
        self.on_evict(node.key, node.value)
    end

    -- 2. Trigger universal removal callback
    if self.on_removed then
        self.on_removed(node.key, node.value)
    end
end

function LRU:get(key)
    local node = self.map[key]
    if not node then return nil end

    self:_remove_links(node)
    self:_insert_front(node)
    return node.value
end

function LRU:peek(key)
    local node = self.map[key]
    return node and node.value or nil
end

function LRU:put(key, value)
    local node = self.map[key]

    if node then
        node.value = value
        self:_remove_links(node)
        self:_insert_front(node)
        return
    end

    if self.count >= self.capacity then
        local lru_node = self.tail
        if lru_node then
            self:_delete_node(lru_node, true)
        end
    end

    node = { key = key, value = value }
    self.map[key] = node
    self:_insert_front(node)
    self.count = self.count + 1
end

function LRU:delete(key)
    local node = self.map[key]
    if node then
        self:_delete_node(node, false)
    end
end

function LRU:has(key)
    return self.map[key] ~= nil
end

function LRU:clear()
    if self.on_removed or self.on_evict then
        while self.head do
            self:_delete_node(self.head, false)
        end
    else
        self.map = {}
        self.count = 0
        self.head = nil
        self.tail = nil
    end
end

function LRU:size()
    return self.count
end

function LRU:items()
    local current = self.head
    return function()
        if not current then return nil end
        local key, value = current.key, current.value
        current = current.next
        return key, value
    end
end

return LRU