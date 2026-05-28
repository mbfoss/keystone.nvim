---@class keystone.SpawnHandle
---@field kill fun()

---@param cmd      string[]
---@param opts     { cwd?: string, stdout?: fun(data:string), stderr?: fun(data:string) }
---@param on_exit  fun(code:integer)
---@return keystone.SpawnHandle
local function spawn(cmd, opts, on_exit)
    local stdout = vim.uv.new_pipe(false)
    local stderr = vim.uv.new_pipe(false)

    -- Pipes closed by force (kill path only — drops buffered data intentionally)
    local function close_pipes()
        if stdout and not stdout:is_closing() then stdout:close() end
        if stderr and not stderr:is_closing() then stderr:close() end
    end

    -- Natural-exit path: wait for both pipes to reach EOF before firing on_exit
    local exit_code
    local pipes_open = 2

    local function on_pipe_closed()
        pipes_open = pipes_open - 1
        if pipes_open == 0 and exit_code ~= nil then
            vim.schedule(function() on_exit(exit_code) end)
        end
    end

    local handle ---@type uv.uv_process_t?
    ---@diagnostic disable-next-line: missing-fields
    handle = vim.uv.spawn(cmd[1], {
        args  = vim.list_slice(cmd, 2),
        cwd   = opts.cwd,
        stdio = { nil, stdout, stderr },
    }, function(code)
        exit_code = code
        local h = handle
        if h and not h:is_closing() then h:close() end
        -- Pipes may still have data; fire on_exit once they drain to EOF
        if pipes_open == 0 then
            vim.schedule(function() on_exit(exit_code) end)
        end
    end)

    if not handle then
        close_pipes()
        vim.schedule(function() on_exit(-1) end)
        return { kill = function() end }
    end

    local out = assert(stdout)
    out:read_start(function(err, data)
        if data and not err and opts.stdout then
            opts.stdout(data)
        elseif data == nil then
            if not out:is_closing() then out:close() end
            on_pipe_closed()
        end
    end)

    local err_pipe = assert(stderr)
    err_pipe:read_start(function(err, data)
        if data and not err and opts.stderr then
            opts.stderr(data)
        elseif data == nil then
            if not err_pipe:is_closing() then err_pipe:close() end
            on_pipe_closed()
        end
    end)

    return {
        kill = function()
            -- close_pipes() stops read callbacks (no EOF will arrive), so set
            -- pipes_open = 0 so the process exit callback can still fire on_exit.
            close_pipes()
            pipes_open = 0
            if handle and not handle:is_closing() then
                handle:kill("sigterm")
            end
        end,
    }
end

return spawn
