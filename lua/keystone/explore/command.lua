local M        = {}

local _uv      = vim.uv
local explorer = require("keystone.explore.explorer")
local fsutil   = require("keystone.util.fsutil")
local uitool   = require("keystone.util.uitool")
local icons    = require("keystone.icons")
local inputwin = require("keystone.util.inputwin")

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

---@param type "file"|"dir"
---@param location string
---@param on_done fun(name:string)
local function _fs_create(type, location, on_done)
    location = vim.fn.fnamemodify(location, ":p:h")
    local function check_name(name)
        if not name or name == "" then return false, "Name cannot be empty" end
        local new_path = vim.fn.fnamemodify(vim.fs.joinpath(location, name), ":p")
        local new_parent_dir = vim.fn.fnamemodify(new_path, ":h")
        if new_parent_dir ~= location then return false, "Invalid name" end
        return true, nil, new_path
    end
    inputwin.open({
            prompt = "Create " .. (type == "dir" and "directory" or "file") .. " in " .. location,
            validate = function(name) return check_name(name) end
        },
        function(name)
            if not name then return end
            local name_ok, name_err, new_path = check_name(name)
            if not name_ok or not new_path then
                vim.notify(name_err or "Invalid name", vim.log.levels.ERROR)
                return
            end
            if type == "dir" then
                local ok, err = vim.uv.fs_mkdir(new_path, 493) -- 493 is octal 0755
                if ok then
                    on_done(name)
                else
                    vim.notify(err or "Failed to create directory", vim.log.levels.ERROR)
                end
            else
                local created, err = fsutil.create_file(new_path)
                if created then
                    on_done(name)
                else
                    vim.notify(err or "Failed to create file", vim.log.levels.ERROR)
                end
            end
        end)
end

---@param path string
---@param on_done fun(name:string)
local function _fs_rename(path, on_done)
    local function check_name(name)
        if not name or name == "" then return false, "Name cannot be empty" end
        local parent_dir = vim.fn.fnamemodify(path, ":h")
        local new_path = vim.fn.fnamemodify(vim.fs.joinpath(parent_dir, name), ":p")
        local new_parent_dir = vim.fn.fnamemodify(new_path, ":h")
        if new_parent_dir ~= parent_dir then return false, "Invalid name" end
        return true, nil, new_path
    end
    local is_dir = fsutil.dir_exists(path)
    inputwin.open({
            prompt = "New " .. (is_dir and "directory" or "file") .. " name",
            default = vim.fn.fnamemodify(path, ":t"),
            validate = function(name) return check_name(name) end
        },
        function(name)
            if not name then return end
            local name_ok, name_err, new_path = check_name(name)
            if not name_ok or not new_path then
                vim.notify(name_err or "Invalid name", vim.log.levels.ERROR)
                return
            end
            local ok, err = fsutil.rename_file(path, new_path)
            if ok then
                on_done(name)
            else
                vim.notify("Rename failed: " .. err, vim.log.levels.ERROR)
            end
        end)
end

---@param path string
---@param recursive boolean
---@param on_done fun()
local function _fs_delete(path, recursive, on_done)
    recursive = recursive == true
    local is_folder = fsutil.dir_exists(path)
    local msg
    if is_folder then
        msg = recursive and "Permanently delete directory and ALL its content\n%s?" or
            "Permanently delete directory\n%s?"
    else
        msg = "Permanently delete file\n%s?"
    end
    uitool.confirm_action(msg:format(path), false, function(confirmed)
        if not confirmed then return end
        local success, err_msg
        if is_folder and recursive then
            success = vim.fn.delete(path, "rf") == 0
            if not success then err_msg = "recursive deletion failed" end
        else
            success, err_msg = os.remove(path)
            if not success then err_msg = err_msg or "deletion failed" end
        end
        if success then
            on_done()
        else
            local type_str = is_folder and "directory" or "file"
            vim.notify(("Failed to delete %s\n%s"):format(type_str, err_msg), vim.log.levels.ERROR)
        end
    end)
end


local function _explore_files()
    local bufname = vim.api.nvim_buf_get_name(0)
    local base_dir = (bufname ~= "" and vim.fn.filereadable(bufname) == 1)
        and vim.fn.fnamemodify(bufname, ":h")
        or vim.fn.getcwd()

    local initial = vim.fn.fnamemodify(bufname, ":t")
    explorer.open({
        prompt = "Explore",
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
                    local entries = {}
                    local pending = 0

                    local function make_entry(name, is_dir, is_link, link_target)
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
                            name = name,
                            supports_preview = not is_dir,
                            selectable = not is_dir,
                            data = { priority = is_dir and 0 or 1 },
                        }
                    end

                    local function finish()
                        table.sort(entries, function(a, b)
                            if a.data.priority ~= b.data.priority then
                                return a.data.priority < b.data.priority
                            end
                            return a.name < b.name
                        end)
                        vim.schedule(function()
                            callback(entries)
                        end)
                    end

                    for _, raw in ipairs(raw_entries) do
                        if raw.ftype == "link" then
                            pending = pending + 1
                            vim.uv.fs_readlink(raw.full_path, function(_, link_target)
                                vim.uv.fs_stat(raw.full_path, function(_, stat)
                                    local is_dir = stat ~= nil and stat.type == "directory"
                                    table.insert(entries, make_entry(raw.name, is_dir, true, link_target))
                                    pending = pending - 1
                                    if pending == 0 then finish() end
                                end)
                            end)
                        else
                            table.insert(entries, make_entry(raw.name, raw.ftype == "directory", false, nil))
                        end
                    end

                    if pending == 0 then finish() end
                end))

            return cancel
        end,
        on_create = function(ctx, on_done)
            if not ctx.path then return end
            local filepath = table.concat(ctx.path, '/')
            _fs_create(ctx.is_dir and "dir" or "file", filepath, on_done)
        end,
        on_rename = function(ctx, on_done)
            if not ctx.path then return end
            local filepath = table.concat(ctx.path, '/')
            _fs_rename(filepath, on_done)
        end,
        on_delete = function(ctx, on_done)
            if not ctx.path then return end
            local filepath = table.concat(ctx.path, '/')
            _fs_delete(filepath, ctx.recursive, on_done)
        end,

    }, function(path)
        if path then
            local filepath = table.concat(path, '/')
            uitool.smart_open_file(filepath)
        end
    end)
end


---@param cmd string
---@param rest string[]
---@return string[]
function M.get_subcommands(cmd, rest)
    return {}
end

---@param cmd string
---@param args string[]
---@param opts vim.api.keyset.create_user_command.command_args
function M.run_command(cmd, args, opts)
    if cmd == "FileSelector" then
        _explore_files()
    end
end

return M
