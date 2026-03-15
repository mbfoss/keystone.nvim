local M = {}

local fntools = require("keystone.tools.fntools")

---@param path string
function M.file_exists(path)
    ---@diagnostic disable-next-line: undefined-field
    local stat = vim.loop.fs_stat(path)
    return stat and stat.type == "file"
end

---@param path string
function M.dir_exists(path)
    ---@diagnostic disable-next-line: undefined-field
    local stat = vim.loop.fs_stat(path)
    return stat and stat.type == "directory"
end

---@param path string
---@return boolean
---@return string|nil
function M.make_dir(path)
    vim.fn.mkdir(path, "p")
    if not vim.fn.isdirectory(path) then
        local errmsg = vim.v.errmsg or ""
        return false, "Failed to create directory: " .. errmsg
    end
    return true
end

---@param filepath string
---@param data string
---@return boolean
---@return string | nil
function M.write_content(filepath, data)
    local fd = io.open(filepath, "w")
    if not fd then
        return false, "Cannot open file for write '" .. filepath or "" .. "'"
    end
    local ok, ret_or_err = pcall(function() fd:write(data) end)
    fd:close()
    return ok, ret_or_err
end

---@param filepath  string
---@return boolean success
---@return string content or error
function M.read_content(filepath)
    local fd = io.open(filepath, "r")
    if not fd then
        return false, "Cannot open file for read '" .. (filepath or "") .. "'"
    end
    local read_ok, content_or_err = pcall(function() return fd:read("*a") end)
    fd:close()
    if not content_or_err then
        return false, "failed to read from file '" .. (filepath or "") .. "'"
    end
    return read_ok, content_or_err
end

---@param path string
---@param opts { max_size: number?, timeout: number? }?
---@param callback fun(err:string|nil, data:string|nil)
---@return fun() abort
function M.async_load_text_file(path, opts, callback)
    opts = opts or {}

    local max_size = (opts.max_size or 1024) * 1024 -- MB → bytes
    local timeout_ms = opts.timeout or 3000
    local uv = vim.uv or vim.loop

    local timer = uv.new_timer()
    local fd = nil
    local chunks = {}
    local total_read = 0
    local offset = 0

    local finished = false
    local aborted = false

    ---@param err string|nil
    ---@param data string|nil
    local function finish(err, data)
        if finished then return end
        finished = true

        -- 1. Stop and cleanup timer
        if timer then
            if not timer:is_closing() then
                timer:stop()
                timer:close()
            end
            timer = nil
        end

        -- 2. Close the file handle safely
        if fd then
            pcall(uv.fs_close, fd)
            fd = nil
        end

        -- 3. Clear chunks to free memory immediately if error occurred
        if err then chunks = {} end

        -- 4. Notify caller on the main loop
        vim.schedule(function()
            if not aborted then
                callback(err, data)
            end
        end)
    end

    -- Start timeout watchdog
    timer:start(timeout_ms, 0, function()
        finish("Timeout", nil)
    end)

    -- Open file
    uv.fs_open(path, "r", 438, function(open_err, opened_fd)
        -- Immediate Guard: If an error occurred or we already timed out/aborted
        if open_err or finished or aborted then
            if opened_fd then pcall(uv.fs_close, opened_fd) end
            if open_err and not (finished or aborted) then
                return finish("Could not open file: " .. open_err, nil)
            end
            return
        end

        fd = opened_fd

        -- Check file stats
        uv.fs_fstat(fd, function(stat_err, stat)
            if finished or aborted then return end
            if stat_err then return finish("Stat error: " .. stat_err, nil) end

            if stat.size > max_size then
                return finish("File exceeds max size limit (" .. opts.max_size .. "MB)", nil)
            end

            local function read_next()
                -- Double check fd is still valid before every read call
                if not fd or finished or aborted then return end

                uv.fs_read(fd, 8192, offset, function(read_err, data)
                    if finished or aborted then return end

                    if read_err then
                        return finish("Read error: " .. read_err, nil)
                    end

                    -- EOF (End of File)
                    if not data or #data == 0 then
                        local final_data = table.concat(chunks)
                        chunks = {} -- Clear reference
                        return finish(nil, final_data)
                    end

                    -- Binary check (Null byte detection)
                    if data:find("\0", 1, true) then
                        return finish("Binary file detected", nil)
                    end

                    total_read = total_read + #data
                    if total_read > max_size then
                        return finish("File exceeds max size limit during read", nil)
                    end

                    table.insert(chunks, data)
                    offset = offset + #data
                    read_next()
                end)
            end

            read_next()
        end)
    end)

    -- Return abort function
    return function()
        if finished or aborted then return end
        aborted = true
        finish("Aborted", nil)
    end
end

---@param dir string Directory path to monitor
---@param change_callback fun(file:string, status:table|nil) Callback called with changed file name
---@return fun() cancel_fn Function that stops the monitoring
function M.monitor_dir(dir, change_callback)
    local uv = vim.uv or vim.loop

    ---@diagnostic disable-next-line: undefined-field
    local handle = uv.new_fs_event()

    local terminated = false

    handle:start(dir, {}, function(err, fname, status)
        if terminated then
            return
        end
        if err then
            vim.schedule(function()
                if not terminated then
                    vim.notify("monitor_dir error: " .. err, vim.log.levels.ERROR)
                end
            end)
            return
        end
        if fname then
            vim.schedule(function()
                if not terminated then
                    change_callback(fname, status)
                end
            end)
        end
    end)
    local function cancel()
        if terminated then
            return
        end
        terminated = true
        if handle then
            if handle:is_active() then
                handle:stop()
            end
            handle:close()
            handle = nil
        end
    end
    return cancel
end

local uv = vim.uv or vim.loop

---@param dir string
---@param exclude_globs string[]
---@param on_file fun(path:string,name:string)
---@param on_done fun()
---@return function # cancel function
function M.async_walk_dir(dir, exclude_globs, on_file, on_done)
    local results_count = 0
    local pending_dirs = { dir }
    local is_cancelled = false

    local function is_excluded(path)
        for _, pat in ipairs(exclude_globs or {}) do
            if path:match(pat) then return true end
        end
        return false
    end

    local function process_next_dir()
        -- 1. Check cancellation or completion immediately
        if is_cancelled then return end

        if #pending_dirs == 0 then
            vim.schedule(function()
                if not is_cancelled then on_done() end
            end)
            return
        end

        local path = table.remove(pending_dirs, 1)

        -- 2. Validate path before opening
        ---@diagnostic disable-next-line: undefined-field
        local fd = uv.fs_scandir(path)
        if not fd then
            -- Skip inaccessible directories and move to next
            vim.schedule(process_next_dir)
            return
        end

        local chunk = {}
        -- 3. Iterate through entries
        while true do
            ---@diagnostic disable-next-line: undefined-field
            local name, type_ = uv.fs_scandir_next(fd)
            if not name then break end

            local full_path = vim.fs.joinpath(path, name)

            -- Directory logic
            if type_ == "directory" then
                if not is_excluded(full_path) then
                    table.insert(pending_dirs, full_path)
                end
                -- File logic
            elseif type_ == "file" then
                if not is_excluded(full_path) then
                    on_file(full_path, name)
                end
            end
        end

        -- 4. Explicitly signal completion of this directory to GC
        fd = nil

        vim.schedule(process_next_dir)
    end

    -- Start the engine
    process_next_dir()

    -- 6. Robust Return cancellation function
    return function()
        is_cancelled = true
        pending_dirs = {} -- Clear references to free memory
    end
end

return M
