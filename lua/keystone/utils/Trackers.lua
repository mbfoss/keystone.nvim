local class = require("keystone.utils.class")

---@class keystone.TrackerRef
---@field cancel fun()

---@class keystone.utils.Trackers
---@field new fun(self: keystone.utils.Trackers) : keystone.utils.Trackers
---@field private _next_id integer
---@field private _items table<integer, table>
local Trackers = class()

local function _pcall_async_report(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        vim.schedule(function()
            vim.api.nvim_echo({ { "[Error] " .. tostring(err), "ErrorMsg" } }, true, {})
        end)
    end

    return ok, err
end

function Trackers:init()
    self._next_id = 0
    self._items = {}
end

---@param callbacks table
---@return keystone.TrackerRef
function Trackers:add_tracker(callbacks)
    local id = self._next_id + 1
    self._next_id = id
    self._items[id] = callbacks

    return {
        cancel = function()
            self._items[id] = nil
        end,
    }
end

---@param callback_name string
---@param ... any
function Trackers:_invoke(callback_name, ...)
    local keys = vim.tbl_keys(self._items)
    for _, k in ipairs(keys) do
        local t = self._items[k]
        local fn = t and t[callback_name]
        if fn then
            _pcall_async_report(fn, ...)
        end
    end
end

---@param callback_name string
---@param ... any
function Trackers:invoke(callback_name, ...)
    local n = select("#", ...)
    local args = {}
    for i = 1, n do
        args[i] = select(i, ...)
    end
    self:_invoke(callback_name, unpack(args, 1, n))
end

return Trackers
