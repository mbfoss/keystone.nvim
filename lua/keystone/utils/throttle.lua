local M = {}

local uv = vim.uv

local function _is_exiting()
    return vim.v.exiting ~= vim.NIL
end

-- Throttle that:
-- • Runs the first call immediately
-- • Guarantees at least `ms` between executions
-- • Never drops a call – if called during cooldown, it will run again exactly when allowed
-- • No arguments, pure side-effect trigger
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

        -- Can run immediately
        if last_exec == 0 or now - last_exec >= ms then
            run()
            return
        end

        -- Already scheduled
        if timer then
            return
        end

        -- Schedule trailing execution
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

--- Fixed-Window Trailing Debounce:
--- • The first call starts a timer and does NOT run immediately.
--- • All calls during the `ms` wait period are completely ignored.
--- • Once `ms` passes, the function executes once.
--- • Only after execution is the system ready to accept a new trigger.
---@param ms number The wait duration in milliseconds.
---@param fn function The function to run.
function M.trailing_fixed_wrap(ms, fn)
    local is_pending = false

    return function(...)
        if is_pending then
            -- We are already waiting for a previous trigger; ignore everything else.
            return
        end

        is_pending = true
        ---@diagnostic disable-next-line: undefined-field
        local timer = uv.new_timer()
        timer:start(ms, 0, function()
            -- Move back to the Neovim main thread for safety
            vim.schedule(function()
                -- Cleanup timer handle
                if timer then
                    if not timer:is_closing() then timer:close() end
                end
                -- Reset state BEFORE running so the function itself
                -- could technically trigger a new debounce if needed.
                is_pending = false
                if not _is_exiting() then
                    fn()
                end
            end)
        end)
    end
end

-- Leading + trailing debounce
-- • First call runs immediately
-- • Subsequent calls reset the timer
-- • When `ms` passes without new calls, fn runs again
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
