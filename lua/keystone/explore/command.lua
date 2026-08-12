local M        = {}

local _uv      = vim.uv
local explorer = require("keystone.explore.explorer")
local fsutil   = require("keystone.util.fsutil")
local ui       = require("keystone.util.ui")
local icons    = require("keystone.icons")

---@alias keystone.explore.DetailField "size"|"mtime"

-- Fields shown in the right-aligned detail column, in order. Configurable via M.configure.
---@type keystone.explore.DetailField[]
local _detail_fields = { "size", "mtime" }

---@param opts {detail_fields:keystone.explore.DetailField[]?}?
function M.configure(opts)
    if opts and opts.detail_fields then
        _detail_fields = opts.detail_fields
    end
end

local _size_units = { "B", "KB", "MB", "GB", "TB", "PB" }

--- Number and unit get their own sub-columns -- right- and left-aligned respectively --
--- so the digits line up the way `ls -lh` stacks them. Returns a fixed 9 cells: the
--- widest number is "1023.9", since a value only carries to the next unit at 1024.
---@param bytes number
---@return string
local function _fmt_size(bytes)
    local value, idx = bytes, 1
    while value >= 1024 and idx < #_size_units do
        value = value / 1024
        idx = idx + 1
    end
    local num = idx == 1 and tostring(value) or ("%.1f"):format(value)
    -- Rounding can carry "1023.95" up to "1024.0"; promote it rather than print that.
    if idx < #_size_units and tonumber(num) >= 1024 then
        idx = idx + 1
        num = ("%.1f"):format(value / 1024)
    end
    return ("%6s %-2s"):format(num, _size_units[idx])
end

--- `ls -l` style: recent timestamps show a clock, older ones a year, and the day is
--- space-padded so both forms occupy the same 12 cells. Built by hand rather than with
--- strftime's `%e`, which MSVC does not support.
---@param mtime_sec number
---@return string
local function _fmt_mtime(mtime_sec)
    local t = os.date("*t", mtime_sec) --[[@as osdate]]
    local month = os.date("%b", mtime_sec) --[[@as string]]
    if (os.time() - mtime_sec) < 15552000 then
        return ("%s %2d %02d:%02d"):format(month, t.day, t.hour, t.min)
    end
    return ("%s %2d  %d"):format(month, t.day, t.year)
end

-- Each field keeps a fixed slot even when it has no value, so a directory's blank
-- size does not slide its mtime into the size column.
local _field_widths = { size = 9, mtime = 12 }

---@param stat uv.fs_stat.result|nil
---@return {[1]:string,[2]:string?}[]
local function _detail_chunks(stat)
    local parts = {}
    for _, field in ipairs(_detail_fields) do
        local width = _field_widths[field]
        if width then
            local text
            if stat then
                if field == "size" and stat.type ~= "directory" then
                    text = _fmt_size(stat.size)
                elseif field == "mtime" then
                    text = _fmt_mtime(stat.mtime.sec)
                end
            end
            table.insert(parts, ("%" .. width .. "s"):format(text or ""))
        end
    end
    if #parts == 0 then return {} end
    return { { "  " .. table.concat(parts, " "), "Comment" } }
end

---@param name string The filename or directory name
---@param is_dir boolean
---@return string icon
---@return string|nil hl_group
local function _get_icon(name, is_dir)
    local icon, icon_hl
    if is_dir then
        icon, icon_hl = "", "Directory"
    else
        local ext = name:match("%.([^.]+)$") or ""
        icon, icon_hl = icons.get_icon(name, ext, { default = false })
    end
    return icon or "", icon_hl
end

---@param target_path string|nil Initial path to open the explorer at. Falls back to the current buffer/cwd when nil.
local function _explore_files(target_path)
    local base_dir, initial
    if target_path and target_path ~= "" then
        local full_path = vim.fn.fnamemodify(vim.fn.expand(target_path), ":p")
        local stat = _uv.fs_stat(full_path)
        if stat and stat.type == "directory" then
            base_dir = full_path
            initial = nil
        else
            base_dir = vim.fn.fnamemodify(full_path, ":h")
            initial = vim.fn.fnamemodify(full_path, ":t")
        end
    else
        local bufname = vim.api.nvim_buf_get_name(0)
        base_dir = (bufname ~= "" and vim.fn.filereadable(bufname) == 1)
            and vim.fn.fnamemodify(bufname, ":h")
            or vim.fn.getcwd()
        initial = vim.fn.fnamemodify(bufname, ":t")
    end
    explorer.open({
        initial_path = vim.split(vim.fs.normalize(base_dir), '/'),
        initial_cursor = initial,
        enable_preview = true,
        finder = function(path_parts, fetch_opts, callback)
            if not path_parts then
                callback({})
                return
            end
            local path = table.concat(path_parts, '/')
            if path == "" then path = "/" end
            local show_hidden = fetch_opts.show_hidden
            local raw_entries = {}
            local cancel = fsutil.async_scan_dir(path, nil, nil,
                function(name, ftype)
                    if not show_hidden and name:sub(1, 1) == "." then return end
                    table.insert(raw_entries, { name = name, ftype = ftype, full_path = vim.fs.joinpath(path, name) })
                end,
                vim.schedule_wrap(function()
                    local pending = 0

                    local function make_entry(name, is_dir, is_link, link_target, stat)
                        local chunks = {
                            { _get_icon(name, is_dir) },
                            { " " },
                            { name },
                        }
                        if is_link then
                            table.insert(chunks, { " " })
                            if link_target then
                                vim.list_extend(chunks, { { "→", "Special" }, { " " }, { link_target, "Special" } })
                            else
                                table.insert(chunks, { "↗", "Special" })
                            end
                        end
                        return {
                            label_chunks = chunks,
                            detail_chunks = _detail_chunks(stat),
                            name = name,
                            supports_preview = not is_dir,
                            selectable = not is_dir,
                            data = { priority = is_dir and 0 or 1 },
                        }
                    end

                    -- Entries are built here rather than in the libuv callbacks: icon
                    -- lookup touches vim APIs that are unavailable in a fast event context.
                    local function finish()
                        local entries = {}
                        for _, raw in ipairs(raw_entries) do
                            local is_dir = raw.is_link
                                and (raw.stat ~= nil and raw.stat.type == "directory")
                                or raw.ftype == "directory"
                            table.insert(entries,
                                make_entry(raw.name, is_dir, raw.is_link, raw.link_target, raw.stat))
                        end
                        table.sort(entries, function(a, b)
                            if a.data.priority ~= b.data.priority then
                                return a.data.priority < b.data.priority
                            end
                            return a.name < b.name
                        end)
                        callback(entries)
                    end

                    pending = #raw_entries
                    if pending == 0 then
                        finish()
                        return
                    end

                    local function entry_done()
                        pending = pending - 1
                        if pending == 0 then vim.schedule(finish) end
                    end

                    for _, raw in ipairs(raw_entries) do
                        if raw.ftype == "link" then
                            raw.is_link = true
                            _uv.fs_readlink(raw.full_path, function(_, link_target)
                                raw.link_target = link_target
                                _uv.fs_stat(raw.full_path, function(_, stat)
                                    raw.stat = stat
                                    entry_done()
                                end)
                            end)
                        else
                            _uv.fs_stat(raw.full_path, function(_, stat)
                                raw.stat = stat
                                entry_done()
                            end)
                        end
                    end
                end))

            return cancel
        end,
    }, function(path)
        if path then
            local filepath = table.concat(path, '/')
            ui.smart_open_file(filepath)
        end
    end)
end


---@param cmd string
---@param rest string[]
---@param arg_lead string
---@return string[]
function M.get_subcommands(cmd, rest, arg_lead)
    if cmd == "FileSelector" and #rest == 0 then
        return vim.fn.getcompletion(arg_lead, "dir")
    end
    return {}
end

---@param cmd string
---@param args string[]
---@param opts vim.api.keyset.create_user_command.command_args
function M.run_command(cmd, args, opts)
    if cmd == "FileSelector" then
        _explore_files(args[1])
    end
end

return M
