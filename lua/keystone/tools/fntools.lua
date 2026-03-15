local M = {}

-- Returns a version of fn that can only be called once
function M.called_once(fn)
    local called = false
    return function(...)
        if called then
            return
        end
        called = true
        return fn(...)
    end
end

---@param timer table?
---@return nil
function M.stop_and_close_timer(timer)
    if timer then
        if timer:is_active() then
            timer:stop()
        end
        if not timer:is_closing() then
            timer:close()
        end
    end
    return nil
end

return M
