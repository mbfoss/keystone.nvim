--- File system manipulation layer for the file tree.
--- The tree/UI layer (keystone.filetree.FileTree) goes through this module for
--- every file system access so it never touches the fs primitives directly.
local fsutil = require("keystone.tk.fsutil")

local M = {}

---@class keystone.filetree.fs.Entry
---@field name string
---@field is_dir boolean
---@field is_link boolean

---@alias keystone.filetree.fs.Filter fun(full_path:string, name:string, is_dir:boolean, is_link:boolean):boolean

---@class keystone.filetree.fs.ScanOpts
---@field follow_symlinks boolean?
---@field filter keystone.filetree.fs.Filter?

---@class keystone.filetree.fs.StatInfo
---@field stat uv.fs_stat.result?
---@field link_target string?

M.file_exists = fsutil.file_exists
M.has_trash = fsutil.has_trash
M.monitor_dir = fsutil.monitor_dir
M.copy_path = fsutil.copy_path
M.rename_path = fsutil.rename_file

--- Resolve raw scandir entries into final entries: stat symlinks (when
--- following them) to detect symlinked directories, and apply the filter.
---@param path string
---@param raw_entries {name:string, type:string}[]
---@param opts keystone.filetree.fs.ScanOpts
---@param callback fun(entries:keystone.filetree.fs.Entry[])
local function _resolve_entries(path, raw_entries, opts, callback)
    local resolved = {} ---@type keystone.filetree.fs.Entry[]
    local pending = #raw_entries
    if pending == 0 then
        callback(resolved)
        return
    end

    ---@type fun(full_path:string, name:string, is_dir:boolean, is_link:boolean)
    local process_entry = function(full_path, name, is_dir, is_link)
        if not is_link or opts.follow_symlinks then
            if not opts.filter or opts.filter(full_path, name, is_dir, is_link) then
                ---@type keystone.filetree.fs.Entry
                local entry = {
                    name = name,
                    is_dir = is_dir,
                    is_link = is_link,
                }
                table.insert(resolved, entry)
            end
        end
        pending = pending - 1
        if pending == 0 then callback(resolved) end
    end

    for _, entry in ipairs(raw_entries) do
        local full_path = vim.fs.joinpath(path, entry.name)
        if entry.type == "link" and opts.follow_symlinks then
            vim.uv.fs_stat(full_path, function(err, stat)
                vim.schedule(function() -- processing inside libuv callback -> crash
                    local is_dir = err == nil and stat ~= nil and stat.type == "directory"
                    process_entry(full_path, entry.name, is_dir, true)
                end)
            end)
        else
            process_entry(full_path, entry.name, entry.type == "directory", entry.type == "link")
        end
    end
end

--- Asynchronously list the entries of a directory. The callback runs on the
--- main loop; on scan failure it receives an empty list and the error message.
---@param path string
---@param opts keystone.filetree.fs.ScanOpts
---@param callback fun(entries:keystone.filetree.fs.Entry[], err:string?)
function M.scan_dir(path, opts, callback)
    vim.uv.fs_scandir(path, function(err, handle)
        vim.schedule(function() -- get out of the fast event context
            local raw_entries = {} ---@type {name:string, type:string}[]
            if handle then
                while true do
                    local name, type = vim.uv.fs_scandir_next(handle)
                    if not name then break end
                    table.insert(raw_entries, { name = name, type = type })
                end
            end
            _resolve_entries(path, raw_entries, opts, function(entries)
                callback(entries, err)
            end)
        end)
    end)
end

--- Create a file or directory at `path`.
---@param path string
---@param as_dir boolean
---@return boolean ok
---@return string? err
function M.create_node(path, as_dir)
    if as_dir then
        local ok, err = vim.uv.fs_mkdir(path, 493) -- 493 is octal 0755
        if not ok then
            return false, err
        end
        return true
    end
    return fsutil.create_file(path)
end

--- Delete `path` (recursively for directories), moving it to the system trash
--- when `use_trash` is true.
---@param path string
---@param use_trash boolean
---@return boolean ok
---@return string? err
function M.delete_path(path, use_trash)
    if use_trash then
        return fsutil.trash_path(path)
    end
    if vim.fn.delete(path, "rf") ~= 0 then
        return false, "delete failed"
    end
    return true
end

--- Asynchronously stat `path`, also resolving the symlink target when
--- `resolve_link` is true. The callback may run in a libuv callback context.
---@param path string
---@param resolve_link boolean
---@param callback fun(info:keystone.filetree.fs.StatInfo)
function M.stat_info(path, resolve_link, callback)
    vim.uv.fs_stat(path, function(_, stat)
        if resolve_link then
            vim.uv.fs_readlink(path, function(_, target)
                callback({ stat = stat, link_target = target })
            end)
        else
            callback({ stat = stat })
        end
    end)
end

return M
