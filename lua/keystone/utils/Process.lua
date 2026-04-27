local uv = require('luv')
local class = require('keystone.utils.class')
local utils = require('keystone.utils.utils')

local function _safe_close(h)
    if h and not h:is_closing() then
        h:close()
    end
end

---@class keystone.Process.Opts
---@field args string[]|nil
---@field env {string:string}|nil
---@field cwd string
---@field on_output fun(data:string, is_stderr:boolean)
---@field on_exit fun(code:number, signal:number)

---@class keystone.Process
---@field new fun(self: keystone.Process, cmd : string, opts : keystone.Process.Opts) : keystone.Process
---@field start fun(self: keystone.Process) : boolean,string?
local Process = class()

---@param cmd string
function Process:init(cmd, opts)
    assert(type(cmd) == "string", "cmd is required")
    assert(opts.cwd, "cwd is required")

    self.cmd = cmd
    self.args = opts.args or {}
    self.cwd = opts.cwd

    if opts.env then
        self.env = vim.fn.copy(opts.env)
    else
        self.env = vim.fn.copy(vim.fn.environ() or {}) -- inherid parent env
    end
    self.env['PWD'] = self.cwd                         -- required for commands to use cwd in all cases

    self.on_output = opts.on_output
    self.on_exit = opts.on_exit

    self.exited = false
    self.killed = false

    return self
end

---@return boolean,string?
function Process:start()
    assert(not self._started)
    self._started = true

    self.stdin = uv.new_pipe(false)
    self.stdout = uv.new_pipe(false)
    self.stderr = uv.new_pipe(false)

    local ok, err_str = self:_spawn()
    if not ok or not self.handle then
        self:_close_all()
        return false, err_str
    end
    return true
end

---@return boolean,string?
function Process:_spawn()
    local opts = {
        args = self.args,
        cwd = self.cwd,
        env = self:_env_list(),
        stdio = { self.stdin, self.stdout, self.stderr },
    }

    local exec_path = vim.fn.exepath(self.cmd)
    if exec_path == nil or exec_path == "" then
        return false, "Program is not executable: " .. tostring(self.cmd)
    end
    local handle, pid_or_err = uv.spawn(exec_path, opts, vim.schedule_wrap(function(code, signal)
        if self.exited then return end
        self.exited = true

        self._kill_timer = utils.stop_and_close_timer(self._kill_timer)
        self:_close_all()
        if self.on_exit then
            self.on_exit(code, signal)
        end
    end))

    if not handle then
        self.exited = true
        return false, ("failed to start process (%s): %s"):format(self.cmd, tostring(pid_or_err))
    end

    self.handle, self.pid = handle, pid_or_err
    local function create_reader(is_stderr)
        local pipe = is_stderr and self.stderr or self.stdout
        pipe:read_start(function(err, data)
            if err then
                vim.schedule(function() error(err) end)
                return
            end
            if data then
                vim.schedule(function() self.on_output(data, is_stderr) end)
            else
                pipe:read_stop() -- Stop polling on EOF
            end
        end)
    end

    create_reader(false) -- stdout
    create_reader(true)  -- stderr
    return true
end

function Process:_env_list()
    assert(self.env)
    local out = {}
    for k, v in pairs(self.env) do
        table.insert(out, string.format("%s=%s", k, v))
    end
    return out
end

function Process:write(data)
    if self.exited then
        return false, "process exited"
    end
    if not self.stdin or self.stdin:is_closing() then
        return false, "stdin closed"
    end
    self.stdin:write(data)
    return true
end

function Process:running()
    return self.handle ~= nil
end

---@param opts {timeout_ms:number?,stop_read:boolean?}?
function Process:kill(opts)
    if self.exited or self.killed then return end
    self.killed = true
    _safe_close(self.stdin)
    if not opts or opts.stop_read then
        _safe_close(self.stdout)
        _safe_close(self.stderr)
    end
    if self.handle and not self.handle:is_closing() then
        self.handle:kill("SIGTERM")
    end
    if opts and opts.timeout_ms then
        vim.defer_fn(function()
            if not self.exited and self.handle and not self.handle:is_closing() then
                self.handle:kill("SIGKILL")
            end
        end, opts.timeout_ms)
    else
        if self.handle and not self.handle:is_closing() then
            self.handle:kill("SIGKILL")
        end
    end
end

function Process:_close_all()
    _safe_close(self.stdin)
    _safe_close(self.stdout)
    _safe_close(self.stderr)
    _safe_close(self.handle)
end

return Process
