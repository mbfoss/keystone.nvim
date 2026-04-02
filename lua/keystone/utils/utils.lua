local M = {}
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
---@param interval number The delay and subsequent interval between executions (in milliseconds).
---@param fn function The callback function to execute.
---@return function stop_timer A function that, when called, stops and cleans up the timer.
function M.start_timer(interval, fn)
    ---@diagnostic disable-next-line: undefined-field
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

function M.deep_merge_tables(dest, src)
    vim.validate({
        dest = { dest, "table" },
        src = { src, "table" },
    })

    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dest[k]) == "table" and not vim.islist(v) then
                M.deep_merge_tables(dest[k], v)
            else
                dest[k] = vim.deepcopy(v)
            end
        else
            dest[k] = v
        end
    end
    return dest
end

return M
