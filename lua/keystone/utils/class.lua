---@generic T
---@param base T|nil
---@return T
local function class(base)
    local c = {}
    c.__index = c
    if base then setmetatable(c, { __index = base }) end
    ---@param ... any
    ---@return table
    function c:new(...)
        local obj = setmetatable({}, self)
        ---@diagnostic disable-next-line: undefined-field
        if obj.init then obj:init(...) end
        return obj
    end

    return c
end

return class
