local M = {}

local uv = vim.uv

local function _is_exiting()
    return vim.v.exiting ~= vim.NIL
end
function M.throttle_wrap(ms, fn)
    local timer = nil
    local last_exec = 0

    return function()
        ---@diagnostic disable-next-line: undefined-field
        local now = uv.now()

        local function run()
            ---@diagnostic disable-next-line: undefined-field
            last_exec = uv.now()
            if not _is_exiting() then
                fn()
            end
        end
        if last_exec == 0 or now - last_exec >= ms then
            run()
            return
        end
        if timer then
            return
        end
        local delay = ms - (now - last_exec)
        ---@diagnostic disable-next-line: undefined-field
        timer = uv.new_timer()
        timer:start(delay, 0, function()
            vim.schedule(function()
                if timer:is_active() then timer:stop() end
                if not timer:is_closing() then timer:close() end
                timer = nil
                run()
            end)
        end)
    end
end
---@param ms number The wait duration in milliseconds.
---@param fn function The function to run.
function M.trailing_fixed_wrap(ms, fn)
    local is_pending = false

    return function(...)
        if is_pending then
            return
        end

        is_pending = true
        ---@diagnostic disable-next-line: undefined-field
        local timer = uv.new_timer()
        timer:start(ms, 0, function()
            vim.schedule(function()
                if timer then
                    if not timer:is_closing() then timer:close() end
                end
                is_pending = false
                if not _is_exiting() then
                    fn()
                end
            end)
        end)
    end
end
function M.leading_idle_debounce(ms, fn)
    ---@diagnostic disable-next-line: undefined-field
    local timer = uv.new_timer()
    local cooling = false
    return function()
        if not cooling then
            cooling = true
            fn()
        end
        timer:stop()
        timer:start(ms, 0, function()
            vim.schedule(function()
                cooling = false
                if not _is_exiting() then
                    fn()
                end
            end)
        end)
    end
end

return M
