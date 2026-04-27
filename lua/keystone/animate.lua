local M = {}

local class = require("keystone.utils.class")

local api = vim.api
local fn = vim.fn
local uv = vim.uv or vim.loop

local function _keycode(str)
    return api.nvim_replace_termcodes(str, true, false, true)
end

local Animate = {
    enabled = function() return true end,
    run = function(from, to, cb, opts)
        local timer = uv.new_timer()
        assert(timer)
        local duration = opts.duration or 100
        local start_time = uv.hrtime() / 1e6

        timer:start(0, 10, vim.schedule_wrap(function()
            local now = uv.hrtime() / 1e6
            local elapsed = now - start_time
            local progress = math.min(elapsed / duration, 1)
            local value = from + (to - from) * progress

            cb(value, { done = progress >= 1 })

            if progress >= 1 then
                timer:stop()
                if not timer:is_closing() then timer:close() end
            end
        end))

        return {
            stop = function()
                if timer:is_active() then timer:stop() end
                if not timer:is_closing() then timer:close() end
            end,
        }
    end,
}

---@class keystone.scroll.State
---@field win number
---@field buf number
---@field view table
---@field current table
---@field target table
---@field changedtick number
---@field last number
---@field _wo table<string, any>
---@field anim table|nil
---@field scrolloff number
---@field new fun(self:keystone.scroll.State, win:number, buf:number, view:table):keystone.scroll.State
local State = class()

local defaults = {
    animate = {
        duration = { step = 10, total = 100 },
        easing = "linear",
    },
    animate_repeat = {
        delay = 100,
        duration = { step = 5, total = 50 },
        easing = "linear",
    },
    filter = function(buf)
        return vim.b[buf].keystone_scroll ~= false and vim.bo[buf].buftype ~= "terminal"
    end,
}

local mouse_scrolling = false
local SCROLL_UP, SCROLL_DOWN = _keycode("<c-y>"), _keycode("<c-e>")
local config = defaults

---@type table<number, keystone.scroll.State>
local states = {}

M.enabled = false

---@param buf number
---@return boolean
local function is_enabled(buf)
    return M.enabled
        and buf
        and not vim.o.paste
        and fn.reg_executing() == ""
        and fn.reg_recording() == ""
        and config.filter(buf)
end

function State:init(win, buf, view)
    self.win = win
    self.buf = buf
    self.view = view
    self.current = vim.deepcopy(view)
    self.target = vim.deepcopy(view)
    self.changedtick = api.nvim_buf_get_changedtick(buf)
    self.last = 0
    self._wo = {}
end

---@param win number
---@return keystone.scroll.State|nil
function State.get(win)
    local buf = api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win)
    if not buf or not is_enabled(buf) then
        states[win] = nil
        return nil
    end

    local view = api.nvim_win_call(win, fn.winsaveview)
    local ret = states[win]

    if not (ret and ret:valid()) then
        if ret then ret:stop() end
        ret = State:new(win, buf, view)
    end

    ret.scrolloff = ret._wo.scrolloff or vim.wo[win].scrolloff
    ret.view = view
    states[win] = ret
    return ret
end

function State:stop()
    self:restore_wo()
    if self.anim then
        self.anim:stop()
        self.anim = nil
    end
end

function State:restore_wo()
    if api.nvim_win_is_valid(self.win) then
        for k, v in pairs(self._wo) do
            vim.wo[self.win][k] = v
        end
    end
    self._wo = {}
end

---@param opts table<string, any>
function State:set_wo(opts)
    for k, v in pairs(opts) do
        self._wo[k] = self._wo[k] or vim.wo[self.win][k]
        vim.wo[self.win][k] = v
    end
end

function State:valid()
    return M.enabled
        and states[self.win] == self
        and api.nvim_win_is_valid(self.win)
        and api.nvim_buf_is_valid(self.buf)
        and api.nvim_win_get_buf(self.win) == self.buf
        and api.nvim_buf_get_changedtick(self.buf) == self.changedtick
end

function State:update()
    if api.nvim_win_is_valid(self.win) then
        self.current = api.nvim_win_call(self.win, fn.winsaveview)
    end
end

function State.reset(win)
    if states[win] then
        states[win]:stop()
        states[win] = nil
    end
end

---@param win number
---@param from table
---@param to table
---@return number
local function scroll_lines(win, from, to)
    local f, t = from, to
    local reverse = false
    if t.topline < f.topline then
        f, t = to, from
        reverse = true
    end

    local height = api.nvim_win_text_height(win, {
        start_row = f.topline - 1,
        end_row = t.topline - 1,
    }).all

    local fill_diff = (t.topfill or 0) - (f.topfill or 0)
    local total = height + fill_diff
    return reverse and -total or total
end

function M.check(win)
    local state = State.get(win)
    if not state then return end

    if vim.wo[state.win].scrollbind and api.nvim_get_current_win() ~= state.win then
        state:stop()
        return
    end

    if mouse_scrolling then
        state:stop()
        mouse_scrolling = false
        state.current = vim.deepcopy(state.view)
        return
    elseif math.abs(state.view.topline - state.current.topline) < 1 and state.view.topfill == state.current.topfill then
        state.current = vim.deepcopy(state.view)
        return
    end

    state.target = vim.deepcopy(state.view)
    state:stop()
    state:set_wo({ virtualedit = "all", scrolloff = 0, smoothscroll = true })

    local now = uv.hrtime()
    local repeat_delta = (now - state.last) / 1e6
    state.last = now

    local is_repeat = repeat_delta <= config.animate_repeat.delay
    local anim_config = is_repeat and config.animate_repeat or config.animate

    local total_rows, move_from, move_to, col_from, col_to = 0, 0, 0, 0, 0

    api.nvim_win_call(state.win, function()
        move_to = fn.winline()
        fn.winrestview(state.current)
        move_from = fn.winline()
        total_rows = scroll_lines(state.win, state.current, state.target)
        col_from = fn.virtcol({ state.current.lnum, state.current.col })
        col_to = fn.virtcol({ state.target.lnum, state.target.col })
    end)

    local is_down = total_rows > 0
    local abs_rows = math.abs(total_rows)
    local scrolled = 0

    state.anim = Animate.run(0, 1, function(progress, ctx)
        if not state:valid() then
            state:stop()
            return
        end

        api.nvim_win_call(win, function()
            if ctx.done then
                fn.winrestview(state.target)
                state:update()
                state:stop()
                return
            end

            local target_scroll = math.floor(abs_rows * progress)
            local diff = target_scroll - scrolled
            if diff > 0 then
                scrolled = scrolled + diff
                api.nvim_command(string.format("keepjumps normal! %d%s", diff, is_down and SCROLL_DOWN or SCROLL_UP))
            end

            local current_winline = math.floor(move_from + (move_to - move_from) * progress)
            local gap = current_winline - fn.winline()
            if gap ~= 0 then
                api.nvim_command(string.format("keepjumps normal! %d%s", math.abs(gap), gap > 0 and "gj" or "gk"))
            end

            local current_col = math.floor(col_from + (col_to - col_from) * progress)
            api.nvim_command(string.format("keepjumps normal! %d|", current_col))

            state:update()
        end)
    end, { duration = anim_config.duration.total })
end

function M.enable()
    if M.enabled then return end
    M.enabled = true
    states = {}

    local group = api.nvim_create_augroup("keystone_scroll", { clear = true })


    api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        callback = vim.schedule_wrap(function(ev)
            for _, win in ipairs(fn.win_findbuf(ev.buf)) do
                State.get(win)
            end
        end),
    })

    api.nvim_create_autocmd({ "InsertLeave", "TextChanged", "TextChangedI" }, {
        group = group,
        callback = function(ev)
            for _, win in ipairs(fn.win_findbuf(ev.buf)) do
                State.get(win)
            end
        end,
    })

    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = group,
        callback = vim.schedule_wrap(function(ev)
            for _, win in ipairs(fn.win_findbuf(ev.buf)) do
                if states[win] then states[win]:update() end
            end
        end),
    })

    api.nvim_create_autocmd({ "CmdlineLeave" }, {
        group = group,
        callback = function(ev)
            if (ev.file == "/" or ev.file == "?") and vim.o.incsearch then
                for _, win in ipairs(fn.win_findbuf(ev.buf)) do
                    State.reset(win)
                end
            end
        end,
    })

    api.nvim_create_autocmd("WinScrolled", {
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

    api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(ev)
            local win = tonumber(ev.match)
            if win then
                State.reset(win)
            end
        end,
    })
end

function M.disable()
    M.enabled = false
    for win in pairs(states) do
        State.reset(win)
    end
    pcall(api.nvim_del_augroup_by_name, "keystone_scroll")
end

function M.setup(opts)
    config = vim.tbl_deep_extend("force", defaults, opts or {})
    M.enable()
end

return M
