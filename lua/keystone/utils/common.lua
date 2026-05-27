local M = {}

---@param interval number The delay and subsequent interval between executions (in milliseconds).
---@param fn function The callback function to execute.
---@return function stop_timer A function that, when called, stops and cleans up the timer.
function M.start_timer(interval, fn)
    local timer = vim.uv.new_timer()
    assert(timer, "Timer creation failed")
    timer:start(interval, interval, vim.schedule_wrap(fn))
    return function()
        if timer then
            if timer:is_active() then
                timer:stop()
            end
            if not timer:is_closing() then
                timer:close()
            end
            timer = nil
        end
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
