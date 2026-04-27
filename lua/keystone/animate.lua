local M = {}

local class = require("keystone.utils.class")

-- Localized APIs for performance
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
---@field win number The window handle
---@field buf number The buffer handle
---@field view table The current window view (winsaveview)
---@field current table The interpolated/current view state
---@field target table The destination view state
---@field changedtick number The buffer changedtick for validation
---@field last number The last animation timestamp (ms)
---@field _wo table<string, any> Stored window options for restoration
---@field anim table|nil The active animation handle
---@field scrolloff number The original scrolloff value
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
    debug = false,
}

local mouse_scrolling = false
local SCROLL_UP, SCROLL_DOWN = _keycode("<c-y>"), _keycode("<c-e>")
local stats = { targets = 0, animating = 0, reset = 0, skipped = 0, mousescroll = 0, scrolls = 0 }
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

local function scroll_lines(win, from, to)
    if from.topline == to.topline then
        return math.abs(from.topfill - to.topfill)
    end

    local f, t = from, to
    if t.topline < f.topline then f, t = to, from end

    local start_row, end_row, offset = f.topline - 1, t.topline - 1, 0
    if f.topfill > 0 then
        start_row = start_row + 1
        offset = f.topfill + 1
    end
    if t.topfill > 0 then
        offset = offset - t.topfill
    end

    if not api.nvim_win_text_height then
        return end_row - start_row + offset
    end
    return api.nvim_win_text_height(win, { start_row = start_row, end_row = end_row }).all + offset - 1
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
        stats.mousescroll = stats.mousescroll + 1
        state.current = vim.deepcopy(state.view)
        return
    elseif math.abs(state.view.topline - state.current.topline) <= 1 then
        stats.skipped = stats.skipped + 1
        state.current = vim.deepcopy(state.view)
        return
    end

    stats.scrolls = stats.scrolls + 1
    stats.targets = stats.targets + 1
    state.target = vim.deepcopy(state.view)
    state:stop()
    state:set_wo({ virtualedit = "all", scrolloff = 0 })

    local now = uv.hrtime()
    local repeat_delta = (now - state.last) / 1e6
    state.last = now

    local is_repeat = repeat_delta <= config.animate_repeat.delay
    local anim_config = is_repeat and config.animate_repeat or config.animate

    local scrolls, move_from, move_to, col_from, col_to = 0, 0, 0, 0, 0

    api.nvim_win_call(state.win, function()
        move_to = fn.winline()
        fn.winrestview(state.current)
        move_from = fn.winline()
        state:update()
        scrolls = scroll_lines(state.win, state.current, state.target)
        col_from = fn.virtcol({ state.current.lnum, state.current.col })
        col_to = fn.virtcol({ state.target.lnum, state.target.col })
    end)

    local is_down = state.target.topline > state.current.topline
        or (state.target.topline == state.current.topline and state.target.topfill < state.current.topfill)

    local scrolled = 0
    state.anim = Animate.run(0, scrolls, function(value, ctx)
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

            local count = vim.v.count
            local commands = {}
            local scroll_target = math.floor(value)
            local scroll_diff = scroll_target - scrolled

            if scroll_diff > 0 then
                scrolled = scrolled + scroll_diff
                table.insert(commands, ("%d%s"):format(scroll_diff, is_down and SCROLL_DOWN or SCROLL_UP))
            end

            local progress_ratio = (scrolls == 0 and 1 or scrolls)
            local move = math.floor(value * math.abs(move_to - move_from) / progress_ratio)
            local move_target = move_from + ((move_to < move_from) and -1 or 1) * move
            table.insert(commands, ("%dH"):format(move_target))

            local virtcol = math.floor(col_from + (col_to - col_from) * value / progress_ratio)
            table.insert(commands, ("%d|"):format(virtcol + 1))

            api.nvim_command(("keepjumps normal! %s"):format(table.concat(commands, "")))

            if vim.v.count ~= count then
                local cursor = api.nvim_win_get_cursor(win)
                api.nvim_command(("keepjumps normal! %dzh"):format(count))
                api.nvim_win_set_cursor(win, cursor)
            end

            state:update()
        end)
    end, { duration = anim_config.duration.total })
end

function M.enable()
    if M.enabled then return end
    M.enabled = true
    states = {}

    for _, win in ipairs(api.nvim_list_wins()) do
        State.get(win)
    end

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

---@class keystone.animate.Config
---@field enabled boolean

local function _get_default_config()
    ---@type keystone.animate.Config
    return { enabled = true }
end

M.config = _get_default_config()

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
