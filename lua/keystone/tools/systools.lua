local M = {}


-- Extracts the executable / process name from a full command line.
-- Handles quotes, paths, both Windows and Unix styles.
function M.get_process_name(cmdline)
    if not cmdline or cmdline == "" then
        return ""
    end

    -- Trim leading/trailing whitespace
    cmdline = cmdline:match("^%s*(.-)%s*$")

    local exe = cmdline

    -- Case 1: Quoted executable: "C:\Program Files\app.exe" -arg
    if exe:sub(1, 1) == '"' then
        exe = exe:match('^"([^"]+)"')
    else
        -- Otherwise, first token until whitespace
        exe = exe:match("^(%S+)")
    end

    if not exe then
        return ""
    end

    -- Normalize Windows slashes
    exe = exe:gsub("\\", "/")

    -- Extract the last path component
    local name = exe:match("([^/]+)$") or exe

    return name
end

---@class keystone.tools.ProcessInfo
---@field pid number
---@field name string
---@field user string|nil  -- username or owner (may be nil on some systems)
---@field cmd string|nil   -- full command line (bonus, available on Unix)

--- Returns a table of running processes with PID, name, and username
---@return keystone.tools.ProcessInfo[]
function M.get_running_processes()
    local processes = {}
    local handle

    local is_windows = package.config:sub(1, 1) == "\\" or os.getenv("OS") == "Windows_NT"

    if is_windows then
        -- Windows: use WMIC with Owner (Username)
        -- Note: GetOwner is slow but reliable
        handle = io.popen('wmic process get ProcessId,Name,UserName /format:list 2>nul')
        if not handle then return processes end

        local current = {}
        for line in handle:lines() do
            local key, value = line:match("^([^=]+)=(.*)$")
            if key and value then
                key = key:gsub("%s+$", "") -- trim right
                if key == "ProcessId" then
                    current.pid = tonumber(value)
                elseif key == "Name" then
                    current.name = value:gsub("%s+$", "")
                elseif key == "UserName" or key == "Owner" then
                    current.user = value ~= "" and value or nil
                end

                -- When we have all fields (or end of record via blank line)
                if current.pid and current.name then
                    table.insert(processes, {
                        pid = current.pid,
                        name = current.name,
                        user = current.user,
                    })
                    current = {}
                end
            end
        end
    else
        -- Linux & macOS: use `ps` with user and full command
        local cmd = [[ps -eww -o user= -o pid= -o command 2>/dev/null]]
        handle = io.popen(cmd)
        if not handle then return processes end

        for line in handle:lines() do
            -- Match: user   pid   full-command...
            local user, pid_str, cmdline = line:match("^%s*(%S+)%s+(%d+)%s+(.*)$")
            local pid = tonumber(pid_str)
            if pid then
                table.insert(processes, {
                    pid = pid,
                    name = M.get_process_name(cmdline),
                    user = user ~= "" and user or nil,
                    cmd = cmdline,
                })
            end
        end
    end

    if handle then handle:close() end
    return processes
end

--- Returns a table of running processes with PID, name, and username
---@return keystone.tools.ProcessInfo[]
function M.get_current_user_processes()
    local all = M.get_running_processes()
    local is_windows = package.config:sub(1, 1) == "\\" or os.getenv("OS") == "Windows_NT"
    local current_user = is_windows and os.getenv("USERNAME") or os.getenv("USER")
    if not current_user then return all end

    local filtered = {}
    for _, proc in ipairs(all) do
        if proc.user == current_user then
            table.insert(filtered, proc)
        end
    end
    return filtered
end

return M
