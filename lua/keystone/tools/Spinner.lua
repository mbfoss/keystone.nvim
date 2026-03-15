local uv = vim.loop

---@alias uv_timer_t table

local class = require('keystone.tools.class')
local fntools = require('keystone.tools.fntools')

---@class keystone.tools.Spinner
---@field frames string[]
---@field interval integer
---@field timer uv_timer_t?
---@field frame integer
---@field running boolean
---@field on_update fun(frame:string, index:integer)?


local default_frames = {
    "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"
}


---@alias keystone.tools.SpinnerOpts {frames?:string[], interval?:integer, on_update?:fun(frame:string, index:integer)}

---@class keystone.tools.Spinner
---@field new fun(self:keystone.tools.Spinner,opts:keystone.tools.SpinnerOpts):keystone.tools.Spinner
local Spinner = class()

---@param opts keystone.tools.SpinnerOpts?
function Spinner:init(opts)
    opts = opts or {}
    self.frames = opts.frames or default_frames
    self.interval = opts.interval or 80
    self.timer = nil
    self.frame = 1
    self.running = false
    self.on_update = opts.on_update
end

function Spinner:start()
    if self.running then
        return
    end
    self.running = true
    ---@diagnostic disable-next-line: undefined-field
    self.timer = uv.new_timer()
    self.timer:start(
        0,
        self.interval,
        vim.schedule_wrap(function()
            if not self.running then
                return
            end

            local frame = self.frames[self.frame]

            if self.on_update then
                self.on_update(frame, self.frame)
            end

            self.frame = (self.frame % #self.frames) + 1
        end)
    )
end

function Spinner:stop()
    if not self.running then
        return
    end
    self.running = false
    self.timer = fntools.stop_and_close_timer(self.timer)
end

return Spinner
