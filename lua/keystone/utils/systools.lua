local M = {}
function M.get_process_name(cmdline)
    if not cmdline or cmdline == "" then
        return ""
    end
    cmdline = cmdline:match("^%s*(.-)%s*$")

    local exe = cmdline
    if exe:sub(1, 1) == '"' then
        exe = exe:match('^"([^"]+)"')
    else
        exe = exe:match("^(%S+)")
    end

    if not exe then
        return ""
    end
    exe = exe:gsub("\\", "/")
    local name = exe:match("([^/]+)$") or exe

    return name
end

---@class keystone.utils.ProcessInfo
---@field pid number
---@field name string
---@field user string|nil  -- username or owner (may be nil on some systems)
---@field cmd string|nil   -- full command line (bonus, available on Unix)
---@return keystone.utils.ProcessInfo[]
function M.get_running_processes()
    local processes = {}
    local handle

    local is_windows = package.config:sub(1, 1) == "\\" or os.getenv("OS") == "Windows_NT"

    if is_windows then
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
        local cmd = [[ps -eww -o user= -o pid= -o command 2>/dev/null]]
        handle = io.popen(cmd)
        if not handle then return processes end

        for line in handle:lines() do
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
---@return keystone.utils.ProcessInfo[]
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
