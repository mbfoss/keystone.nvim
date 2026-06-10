
---@class keystone.animate
local M = {}

local _ns_name_onkey = "keystone_animate_onkey"
local _augroup_name = "keystone_animate"

---@alias keysstone.animate.easing_fn fun(i:number):number

---@class keystone.animate.Config
---@field enabled boolean?
---@field filter function?
---@field easing keysstone.animate.easing_fn?
---@field speed number? Animation speed in milliseconds per line (default: 8)
---@field duration number? Hard cap on animation duration in milliseconds (default: 300)
---@field step number? Frame interval in milliseconds (default: 16)

local function _get_default_config()
    ---@type keystone.animate.Config
    return {
        enabled = true,
        filter = nil,
        easing = nil,
        speed = 20,
        duration = 300,
        step = 16,
    }
end

---@type keystone.animate.Config
M.config = _get_default_config()

local function _keycode(str)
    return vim.api.nvim_replace_termcodes(str, true, false, true)
end

local function _filter(buf)
    if vim.b[buf].keystone_scroll ~= false and vim.bo[buf].buftype ~= "terminal" then
        if M.config.filter then return M.config.filter(buf) else return true end
    end
    return false
end

--- Determines the amount of scrollable lines between two window views,
--- taking folds and virtual lines into account.
---@param from vim.fn.winsaveview.ret
---@param to vim.fn.winsaveview.ret
local function _scroll_lines(win, from, to)
    if from.topline == to.topline then
        return math.abs(from.topfill - to.topfill)
    end
    if to.topline < from.topline then
        from, to = to, from
    end
    local start_row, end_row, offset = from.topline - 1, to.topline - 1, 0
    if from.topfill > 0 then
        start_row = start_row + 1
        offset = from.topfill + 1
    end
    if to.topfill > 0 then
        offset = offset - to.topfill
    end
    if not vim.api.nvim_win_text_height then
        return end_row - start_row + offset
    end
    return vim.api.nvim_win_text_height(win, { start_row = start_row, end_row = end_row }).all + offset - 1
end

local _easing = {
    linear = function(t) return t end,
    out_quad = function(t) return 1 - (1 - t) * (1 - t) end,
    in_out = function(t)
        return t < 0.5
            and 2 * t * t
            or 1 - math.pow(-2 * t + 2, 2) / 2
    end,
}

---@param from number
---@param to number
---@param cb fun(value:number, ctx:{done:boolean})
---@param opts? { duration?:number, step?:number, easing?:keysstone.animate.easing_fn }
---@return {stop:function, extend:fun(new_to:number, new_duration?:number, new_easing?:keysstone.animate.easing_fn)}
local function _animate(from, to, cb, opts)
    opts = opts or {}

    local _to = to
    local duration = opts.duration or 120 -- total ms
    local step = opts.step or 16          -- frame interval
    local _easing_fn = opts.easing or _easing.in_out

    local timer = assert(vim.uv.new_timer())
    local start = vim.uv.hrtime() / 1e6
    local function stop()
        if timer:is_active() then timer:stop() end
        if not timer:is_closing() then timer:close() end
    end
    timer:start(0, step, vim.schedule_wrap(function()
        local now = vim.uv.hrtime() / 1e6
        local elapsed = now - start
        local t = math.min(elapsed / duration, 1)

        local value = from + (_to - from) * _easing_fn(t)

        cb(value, { done = t >= 1 })

        if t >= 1 then
            stop()
        end
    end))
    -- extend: retarget and restart the clock without touching the timer
    local function extend(new_to, new_duration, new_easing)
        _to = new_to
        if new_duration then duration = new_duration end
        if new_easing then _easing_fn = new_easing end
        start = vim.uv.hrtime() / 1e6
    end
    return { stop = stop, extend = extend }
end


---@alias keystone.animate.View {topline:number, lnum:number}

---@class keystone.animate.AnimParams
---@field scrolls number
---@field move_from number
---@field move_to number
---@field col_from number
---@field col_to number
---@field down boolean
---@field scrolled number

---@class keystone.animate.State
---@field anim? {stop:function, extend:fun(new_to:number, new_duration?:number, new_easing?:keysstone.animate.easing_fn)}
---@field _anim_params? keystone.animate.AnimParams
---@field win number
---@field buf number
---@field view vim.fn.winsaveview.ret
---@field current vim.fn.winsaveview.ret
---@field target vim.fn.winsaveview.ret
---@field scrolloff number
---@field changedtick number
---@field _wo vim.wo Backup of window options
local State = {}
State.__index = State

local _mouse_scrolling = false

M.enabled = false
local _SCROLL_UP, _SCROLL_DOWN = _keycode("<c-y>"), _keycode("<c-e>")

local _stats = { targets = 0, animating = 0, reset = 0, skipped = 0, mousescroll = 0, scrolls = 0 }
local _states = {} ---@type table<number, keystone.animate.State>

local function _is_enabled(buf)
    return M.enabled
        and buf
        and not vim.o.paste
        and vim.fn.reg_executing() == ""
        and vim.fn.reg_recording() == ""
        and _filter(buf)
end

function State:stop()
    self:wo() -- restore window options
    if self.anim then
        self.anim:stop()
        self.anim = nil
    end
end

--- Save or restore window options
---@param opts? vim.wo|{}
function State:wo(opts)
    if not opts then
        if vim.api.nvim_win_is_valid(self.win) then
            for k, v in pairs(self._wo) do
                vim.wo[self.win][k] = v
            end
        end
        self._wo = {}
        return
    else
        for k, v in pairs(opts) do
            self._wo[k] = self._wo[k] or vim.wo[self.win][k]
            vim.wo[self.win][k] = v
        end
    end
end

function State:valid()
    return M.enabled
        and _states[self.win] == self
        and vim.api.nvim_win_is_valid(self.win)
        and vim.api.nvim_buf_is_valid(self.buf)
        and vim.api.nvim_win_get_buf(self.win) == self.buf
        and vim.api.nvim_buf_get_changedtick(self.buf) == self.changedtick
end

function State:update()
    if vim.api.nvim_win_is_valid(self.win) then
        self.current = vim.api.nvim_win_call(self.win, vim.fn.winsaveview)
    end
end

---@private
---@param win number
local function _get_state(win)
    local buf = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
    if not buf or not _is_enabled(buf) then
        _states[win] = nil
        return nil
    end

    local view = vim.api.nvim_win_call(win, vim.fn.winsaveview) ---@type vim.fn.winsaveview.ret
    local ret = _states[win]
    if not (ret and ret:valid()) then
        if ret then
            ret:stop()
        end
        ret = setmetatable({}, State)
        ret.buf = buf
        ret._wo = {}
        ret.changedtick = vim.api.nvim_buf_get_changedtick(buf)
        ret.current = vim.deepcopy(view)
        ret.target = vim.deepcopy(view)
        ret.win = win
    end
    ret.scrolloff = ret._wo.scrolloff or vim.wo[win].scrolloff
    ret.view = view
    _states[win] = ret
    return ret
end

--- Reset the scroll state for a buffer
---@param win number
local function _reset_state(win)
    if _states[win] then
        _states[win]:stop()
        _states[win] = nil
    end
end

function M.enable()
    if M.enabled then
        return
    end

    M.enabled = true
    _states = {}

    -- get initial state for all windows
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        _get_state(win)
    end

    local function on_key(key)
        -- compare against raw keycodes
        if key == vim.api.nvim_replace_termcodes("<ScrollWheelDown>", true, false, true)
            or key == vim.api.nvim_replace_termcodes("<ScrollWheelUp>", true, false, true) then
            _mouse_scrolling = true
        end
    end

    -- attach
    vim.on_key(on_key, vim.api.nvim_create_namespace(_ns_name_onkey))

    local group = vim.api.nvim_create_augroup(_augroup_name, { clear = true })

    -- initialize state for buffers entering windows
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        callback = vim.schedule_wrap(function(ev)
            for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
                _get_state(win)
            end
        end),
    })

    -- update state when leaving insert mode or changing text in normal mode
    vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged", "TextChangedI" }, {
        group = group,
        callback = function(ev)
            for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
                _get_state(win)
            end
        end,
    })

    -- update current state on cursor move
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = group,
        callback = vim.schedule_wrap(function(ev)
            for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
                if _states[win] then
                    _states[win]:update()
                end
            end
        end),
    })

    -- clear scroll state when leaving the cmdline after a search with incsearch
    vim.api.nvim_create_autocmd({ "CmdlineLeave" }, {
        group = group,
        callback = function(ev)
            if (ev.file == "/" or ev.file == "?") and vim.o.incsearch then
                for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
                    _reset_state(win)
                end
            end
        end,
    })

    -- listen to scroll events with topline changes
    vim.api.nvim_create_autocmd("WinScrolled", {
        group = group,
        callback = function()
            for win, changes in pairs(vim.v.event) do
                win = tonumber(win)
                if win and changes.topline ~= 0 then
                    M.check(win)
                end
            end
        end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(args)
            local win = tonumber(args.match)
            if win then
                _reset_state(win)
            end
        end,
    })
end

function M.disable()
    if not M.enabled then
        return
    end
    M.enabled = false
    for _, state in pairs(_states) do state:stop() end
    _states = {}
    vim.on_key(nil, vim.api.nvim_create_namespace(_ns_name_onkey))
    vim.api.nvim_del_augroup_by_name(_augroup_name)
end

--- Check if we need to animate the scroll
---@param win number
---@private
function M.check(win)
    local state = _get_state(win)
    if not state then
        return
    end

    -- only animate the current window when scrollbind is enabled
    if vim.wo[state.win].scrollbind and vim.api.nvim_get_current_win() ~= state.win then
        state:stop()
        return
    end

    -- if delta is 0, then we're animating.
    -- also skip if the difference is less than the mousescroll value,
    -- since most terminals support smooth mouse scrolling.
    if _mouse_scrolling then
        state:stop()
        _mouse_scrolling = false
        _stats.mousescroll = _stats.mousescroll + 1
        state.current = vim.deepcopy(state.view)
        return
    elseif math.abs(state.view.topline - state.current.topline) <= 1 then
        _stats.skipped = _stats.skipped + 1
        state.current = vim.deepcopy(state.view)
        return
    end
    _stats.scrolls = _stats.scrolls + 1

    -- new target
    _stats.targets = _stats.targets + 1
    state.target = vim.deepcopy(state.view)

    -- recompute animation parameters from the current visual position to the new target
    ---@type keystone.animate.AnimParams
    local p = { scrolls = 0, move_from = 0, move_to = 0, col_from = 0, col_to = 0, down = false, scrolled = 0 }
    vim.api.nvim_win_call(state.win, function()
        p.move_to = vim.fn.winline()
        vim.fn.winrestview(state.current) -- rewind to current animated position
        p.move_from = vim.fn.winline()
        state:update()
        p.scrolls = _scroll_lines(state.win, state.current, state.target)
        p.col_from = vim.fn.virtcol({ state.current.lnum, state.current.col }) --[[@as integer]]
        p.col_to = vim.fn.virtcol({ state.target.lnum, state.target.col }) --[[@as integer]]
    end)
    p.down = state.target.topline > state.current.topline
        or (state.target.topline == state.current.topline and state.target.topfill < state.current.topfill)

    if p.scrolls == 0 then
        state:stop()
        return
    end

    local duration = math.min(M.config.duration or 300, p.scrolls * (M.config.speed or 20))

    -- if an animation is already running, just retarget it — no stop/start gap
    if state.anim then
        state._anim_params = p
        state.anim.extend(p.scrolls, duration, _easing.linear)
        return
    end

    state:wo({ virtualedit = "all", scrolloff = 0 })
    state._anim_params = p

    state.anim = _animate(0, p.scrolls, function(value, ctx)
        if not state:valid() then
            state:stop()
            return
        end

        vim.api.nvim_win_call(win, function()
            if ctx.done then
                vim.fn.winrestview(state.target)
                state:update()
                state:stop()
                return
            end

            local _p = state._anim_params ---@type keystone.animate.AnimParams
            local count = vim.v.count -- backup count
            local commands = {} ---@type string[]

            -- scroll
            local scroll_target = math.floor(value)
            local scroll = scroll_target - _p.scrolled --[[@as number]]
            if scroll > 0 then
                _p.scrolled = _p.scrolled + scroll
                commands[#commands + 1] = ("%d%s"):format(scroll, _p.down and _SCROLL_DOWN or _SCROLL_UP)
            end

            -- move the cursor vertically
            local move = math.floor(value * math.abs(_p.move_to - _p.move_from) / _p.scrolls)
            local move_target = _p.move_from + ((_p.move_to < _p.move_from) and -1 or 1) * move
            commands[#commands + 1] = ("%dH"):format(move_target)

            -- move the cursor horizontally
            local virtcol = math.floor(_p.col_from + (_p.col_to - _p.col_from) * value / _p.scrolls)
            commands[#commands + 1] = ("%d|"):format(virtcol + 1)

            -- execute all commands in one go
            vim.cmd(("keepjumps normal! %s"):format(table.concat(commands, "")))

            -- restore count
            if vim.v.count ~= count then
                local cursor = vim.api.nvim_win_get_cursor(win)
                vim.cmd(("keepjumps normal! %dzh"):format(count))
                vim.api.nvim_win_set_cursor(win, cursor)
            end

            state:update()
        end)
    end, { duration = duration, step = M.config.step, easing = M.config.easing })
end

---@param opts keystone.animate.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

    if M.config.enabled then
        M.enable()
    else
        M.disable()
    end
end

return M
