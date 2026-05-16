local M = {}

local uv = vim.uv

local function _is_exiting()
    return vim.v.exiting ~= vim.NIL
end

---Create a throttled wrapper around a function.
---
---The wrapped function executes immediately on the first call, then
---suppresses subsequent calls until the throttle window has elapsed.
---If calls occur during the cooldown period, exactly one trailing
---execution is scheduled.
---
---  - Leading execution: yes
---  - Trailing execution: yes (single queued run)
---  - Re-entrant calls during cooldown are ignored once a timer exists
---
---@param ms number Throttle interval in milliseconds.
---@param fn function Function to throttle.
---@return function wrapped Throttled wrapper function.
function M.throttle_wrap(ms, fn)
    local timer = nil
    local last_exec = 0

    return function()
        local now = uv.now()

        local function run()
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
        timer = uv.new_timer()
        assert(timer)
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

---Create a leading-only throttle wrapper.
---
---The wrapped function executes immediately on the first call, then
---ignores all subsequent calls until the cooldown window has elapsed.
---
---Unlike `throttle_wrap`, this variant does NOT schedule a trailing
---execution after the cooldown period.
---
---Behavior:
---  - Leading execution: yes
---  - Trailing execution: no
---  - Repeated calls during cooldown are ignored
---
---@param ms number Throttle interval in milliseconds.
---@param fn function Function to throttle.
---@return function wrapped Throttled wrapper function.
function M.leading_throttle_wrap(ms, fn)
    local last_exec = 0
    return function(...)
        local now = uv.now()
        if last_exec ~= 0 and (now - last_exec) < ms then
            return
        end
        last_exec = now
        if not _is_exiting() then
            fn(...)
        end
    end
end

---Create a fixed-delay trailing wrapper.
---
---The wrapped function executes once after `ms` milliseconds from the
---first invocation. Additional calls during the waiting period are ignored.
---
---Unlike a debounce:
---  - The timer is NOT reset by repeated calls.
---  - Only one pending execution may exist at a time.
---
---Behavior:
---  - Leading execution: no
---  - Trailing execution: yes
---  - Timer resets on repeated calls: no
---
---@param ms number Wait duration in milliseconds.
---@param fn function Function to execute.
---@return function wrapped Wrapped function.
function M.trailing_fixed_wrap(ms, fn)
    local is_pending = false

    return function(...)
        if is_pending then
            return
        end

        is_pending = true
        local timer = uv.new_timer()
        assert(timer)
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

return M
