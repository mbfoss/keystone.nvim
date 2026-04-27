---@class snacks.animate
local M = {}

---@class keystone.animate.Config
---@field enabled boolean?
---@field filter function?
---@field animate_repeat number?

local function _get_default_config()
    ---@type keystone.animate.Config
    return {
        enabled = true,
        filter = nil,
    }
end

---@type keystone.animate.Config
local config = _get_default_config()

local function _keycode(str)
    return vim.api.nvim_replace_termcodes(str, true, false, true)
end

local function _filter(buf)
    if vim.b[buf].keystone_scroll ~= false and vim.bo[buf].buftype ~= "terminal" then
        if config.filter then return config.filter(buf) else return true end
    end
    return false
end

local Animate = {}

---@param from number
---@param to number
---@param cb fun(value:number, ctx:{done:boolean})
---@param opts? { duration?:number, step?:number, easing?:fun(t:number):number }
function Animate.run(from, to, cb, opts)
    opts = opts or {}

    local duration = opts.duration or 120 -- total ms
    local step = opts.step or 16          -- frame interval
    local easing = opts.easing or function(t) return t end

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

        local eased = easing(t)
        local value = from + (to - from) * eased

        cb(value, { done = t >= 1 })

        if t >= 1 then
            stop()
        end
    end))

    return { stop = stop }
end

Animate.easing = {
    linear = function(t) return t end,
    out_quad = function(t) return 1 - (1 - t) * (1 - t) end,
    in_out = function(t)
        return t < 0.5
            and 2 * t * t
            or 1 - math.pow(-2 * t + 2, 2) / 2
    end,
}


---@alias snacks.animate.View {topline:number, lnum:number}

---@class snacks.animate.State
---@field anim? table
---@field win number
---@field buf number
---@field view vim.fn.winsaveview.ret
---@field current vim.fn.winsaveview.ret
---@field target vim.fn.winsaveview.ret
---@field scrolloff number
---@field changedtick number
---@field last number vim.uv.hrtime of last scroll
---@field _wo vim.wo Backup of window options
local State = {}
State.__index = State

local mouse_scrolling = false

M.enabled = false
local SCROLL_UP, SCROLL_DOWN = _keycode("<c-y>"), _keycode("<c-e>")

local uv = vim.uv or vim.loop
local stats = { targets = 0, animating = 0, reset = 0, skipped = 0, mousescroll = 0, scrolls = 0 }
local debug_timer = assert((vim.uv or vim.loop).new_timer())
local states = {} ---@type table<number, snacks.animate.State>

local function is_enabled(buf)
    return M.enabled
        and buf
        and not vim.o.paste
        and vim.fn.reg_executing() == ""
        and vim.fn.reg_recording() == ""
        and _filter(buf)
end

---@param win number
function State.get(win)
    local buf = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
    if not buf or not is_enabled(buf) then
        states[win] = nil
        return nil
    end

    local view = vim.api.nvim_win_call(win, vim.fn.winsaveview) ---@type vim.fn.winsaveview.ret
    local ret = states[win]
    if not (ret and ret:valid()) then
        if ret then
            ret:stop()
        end
        ret = setmetatable({}, State)
        ret.buf = buf
        ret._wo = {}
        ret.changedtick = vim.api.nvim_buf_get_changedtick(buf)
        ret.current = vim.deepcopy(view)
        ret.last = 0
        ret.target = vim.deepcopy(view)
        ret.win = win
    end
    ret.scrolloff = ret._wo.scrolloff or vim.wo[win].scrolloff
    ret.view = view
    states[win] = ret
    return ret
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
        and states[self.win] == self
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

--- Reset the scroll state for a buffer
---@param win number
function State.reset(win)
    if states[win] then
        states[win]:stop()
        states[win] = nil
    end
end

function M.enable()
    if M.enabled then
        return
    end
    M.enabled = true
    states = {}
    -- get initial state for all windows
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        State.get(win)
    end

    local group = vim.api.nvim_create_augroup("snacks_scroll", { clear = true })

    local function on_key(key)
        -- compare against raw keycodes
        if key == vim.api.nvim_replace_termcodes("<ScrollWheelDown>", true, false, true)
            or key == vim.api.nvim_replace_termcodes("<ScrollWheelUp>", true, false, true) then
            mouse_scrolling = true
        end
    end
    -- attach (namespace required)
    local ns = vim.api.nvim_create_namespace("snacks_animate_scrollwheel")
    vim.on_key(on_key, ns)

    -- initialize state for buffers entering windows
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        callback = vim.schedule_wrap(function(ev)
            for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
                State.get(win)
            end
        end),
    })

    -- update state when leaving insert mode or changing text in normal mode
    vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged", "TextChangedI" }, {
        group = group,
        callback = function(ev)
            for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
                State.get(win)
            end
        end,
    })

    -- update current state on cursor move
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = group,
        callback = vim.schedule_wrap(function(ev)
            for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
                if states[win] then
                    states[win]:update()
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
                    State.reset(win)
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
end

function M.disable()
    if not M.enabled then
        return
    end
    M.enabled = false
    states = {}
    vim.api.nvim_del_augroup_by_name("snacks_scroll")
end

--- Determines the amount of scrollable lines between two window views,
--- taking folds and virtual lines into account.
---@param from vim.fn.winsaveview.ret
---@param to vim.fn.winsaveview.ret
local function scroll_lines(win, from, to)
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

--- Check if we need to animate the scroll
---@param win number
---@private
function M.check(win)
    local state = State.get(win)
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
    if mouse_scrolling then
        state:stop()
        mouse_scrolling = false
        stats.mousescroll = stats.mousescroll + 1
        state.current = vim.deepcopy(state.view)
        return
    elseif math.abs(state.view.topline - state.current.topline) <= 1 then
        stats.skipped = stats.skipped + 1
        state.current = vim.deepcopy(state.view)
        return
    end
    stats.scrolls = stats.scrolls + 1

    -- new target
    stats.targets = stats.targets + 1
    state.target = vim.deepcopy(state.view)
    state:stop() -- stop any ongoing animation
    state:wo({ virtualedit = "all", scrolloff = 0 })

    local now = uv.hrtime()
    local repeat_delta = (now - state.last) / 1e6
    state.last = now

    local opts = {}

    local scrolls = 0
    local col_from, col_to = 0, 0
    local move_from, move_to = 0, 0
    vim.api.nvim_win_call(state.win, function()
        move_to = vim.fn.winline()
        vim.fn.winrestview(state.current) -- reset to current state
        move_from = vim.fn.winline()
        state:update()
        -- calculate the amount of lines to scroll, taking folds into account
        scrolls = scroll_lines(state.win, state.current, state.target)
        col_from = vim.fn.virtcol({ state.current.lnum, state.current.col })
        col_to = vim.fn.virtcol({ state.target.lnum, state.target.col })
    end)

    local down = state.target.topline > state.current.topline
        or (state.target.topline == state.current.topline and state.target.topfill < state.current.topfill)

    local scrolled = 0

    state.anim = Animate.run(0, scrolls, function(value, ctx)
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

            local count = vim.v.count -- backup count
            local commands = {} ---@type string[]

            -- scroll
            local scroll_target = math.floor(value)
            local scroll = scroll_target - scrolled --[[@as number]]
            if scroll > 0 then
                scrolled = scrolled + scroll
                commands[#commands + 1] = ("%d%s"):format(scroll, down and SCROLL_DOWN or SCROLL_UP)
            end

            -- move the cursor vertically
            local move = math.floor(value * math.abs(move_to - move_from) / scrolls)   -- delta to move this step
            local move_target = move_from + ((move_to < move_from) and -1 or 1) * move -- target line
            commands[#commands + 1] = ("%dH"):format(move_target)

            -- move the cursor horizontally
            local virtcol = math.floor(col_from + (col_to - col_from) * value / scrolls)
            commands[#commands + 1] = ("%d|"):format(virtcol + 1)

            -- execute all commands in one go
            vim.cmd(("keepjumps normal! %s"):format(table.concat(commands, "")))

            -- restore count (see #1024)
            if vim.v.count ~= count then
                local cursor = vim.api.nvim_win_get_cursor(win)
                vim.cmd(("keepjumps normal! %dzh"):format(count))
                vim.api.nvim_win_set_cursor(win, cursor)
            end

            state:update()
        end)
    end, opts)
end

---@param opts keystone.lspwords.Config?
function M.setup(opts)
    config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

    if config.enabled then
        M.enable()
    else
        M.disable()
    end
end

return M
