local M        = {}

local _uv      = vim.uv
local explorer = require("keystone.explore.explorer")
local fsutil   = require("keystone.tk.fsutil")
local ui       = require("keystone.tk.ui")
local icons    = require("keystone.icons")

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
    }, function(path)
        if path then
            local filepath = table.concat(path, '/')
            ui.smart_open_file(filepath)
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
