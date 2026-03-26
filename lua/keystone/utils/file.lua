local M = {}

local utils = require("keystone.utils.utils")
local strtools = require("keystone.utils.strtools")

---@param path string
function M.file_exists(path)
    ---@diagnostic disable-next-line: undefined-field
    local stat = vim.keystone.fs_stat(path)
    return stat and stat.type == "file"
end

---@param path string
function M.dir_exists(path)
    ---@diagnostic disable-next-line: undefined-field
    local stat = vim.keystone.fs_stat(path)
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

---@param path string
---@return boolean
---@return string? -- error msg
function M.create_file(path)
    -- "wx" : Open for Writing, fail if file eXists (Atomic)
    -- 420  : Octal 0644 (Read/Write for owner, Read for others)
    ---@diagnostic disable-next-line: undefined-field
    local fd, err, err_name = vim.uv.fs_open(path, "wx", 420)
    if not fd then
        if err_name == "EEXIST" then
            return false, "File already exists"
        end
        return false, "Failed to create file: " .. tostring(err)
    end
    -- Always close the file descriptor if it was opened successfully
    ---@diagnostic disable-next-line: undefined-field
    vim.uv.fs_close(fd)
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

    ---@diagnostic disable-next-line: undefined-field
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
            ---@diagnostic disable-next-line: undefined-field
            uv.fs_close(fd)
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
    local timeout_timer = vim.defer_fn(function()
        finish("Timeout", nil)
    end, timeout_ms)

    -- Open file
    ---@diagnostic disable-next-line: undefined-field
    uv.fs_open(path, "r", 438, function(open_err, opened_fd)
        -- Immediate Guard: If an error occurred or we already timed out/aborted
        if open_err or finished or aborted then
            ---@diagnostic disable-next-line: undefined-field
            if opened_fd then uv.fs_close(opened_fd) end
            if open_err and not (finished or aborted) then
                return finish("Could not open file: " .. open_err, nil)
            end
            return
        end

        fd = opened_fd

        -- Check file stats
        ---@diagnostic disable-next-line: undefined-field
        uv.fs_fstat(fd, function(stat_err, stat)
            if finished or aborted then return end
            if stat_err then return finish("Stat error: " .. stat_err, nil) end

            if stat.size > max_size then
                return finish("File exceeds max size limit (" .. max_size .. "MB)", nil)
            end

            local function read_next()
                -- Double check fd is still valid before every read call
                if not fd or finished or aborted then return end

                ---@diagnostic disable-next-line: undefined-field
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
                        return finish("Binary file", nil)
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
        utils.stop_and_close_timer(timeout_timer)
        finish("Aborted", nil)
    end
end

---@param dir string Directory path to monitor
---@param change_callback fun(file:string, status:table|nil) Callback called with changed file name
---@return fun()? cancel_fn Function that stops the monitoring
---@return string? error message
function M.monitor_dir(dir, change_callback)
    local uv = vim.uv or vim.loop

    ---@diagnostic disable-next-line: undefined-field
    local handle, err_msg = uv.new_fs_event()
    if not handle then
        return nil, err_msg
    end

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
            vim.schedule(function() --callback ousdie the uv loop
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
                ---@diagnostic disable-next-line: undefined-field
                uv.fs_event_stop(handle)
            end
            handle:close()
            handle = nil
        end
    end
    return cancel
end

local uv = vim.uv or vim.loop

---@param dir string
---@param include_regex_list vim.regex[]?
---@param exclude_regex_list vim.regex[]?
---@param on_file fun(path:string,name:string,rel_path:string)
---@param on_done fun()
---@return function # cancel function
function M.async_walk_dir(dir, include_regex_list, exclude_regex_list, on_file, on_done)
    local pending_dirs = { dir }
    local is_cancelled = false

    local on_done_called = false
    local call_on_done = function()
        if not on_done_called then
            vim.schedule(function()
                on_done()
            end)
            on_done_called = true
        end
    end
    local function process_next_dir()
        -- 1. Check cancellation or completion immediately
        if is_cancelled then
            call_on_done()
            return
        end

        if #pending_dirs == 0 then
            call_on_done()
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

        -- 3. Iterate through entries
        while true do
            ---@diagnostic disable-next-line: undefined-field
            local name, type_ = uv.fs_scandir_next(fd)
            if not name then break end

            local full_path = vim.fs.joinpath(path, name)
            local rel_path = vim.fs.relpath(dir, full_path)
            if rel_path then
                -- Directory logic
                if type_ == "directory" then
                    if strtools.check_path_pattern(rel_path, true, nil, exclude_regex_list) then
                        table.insert(pending_dirs, full_path)
                    end
                    -- File logic
                elseif type_ == "file" then
                    if strtools.check_path_pattern(rel_path, false, include_regex_list, exclude_regex_list) then
                        on_file(full_path, name, rel_path)
                    end
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
