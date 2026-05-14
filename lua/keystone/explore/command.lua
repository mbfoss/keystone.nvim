local M        = {}

local uv       = vim.uv
local explorer = require("keystone.explore.explorer")
local fsutils  = require("keystone.utils.fsutils")
local uitools  = require("keystone.utils.uitools")
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
        async_fetch = function(path_parts, fetch_opts, callback)
            if not path_parts then
                callback({})
                return function() end
            end
            local path = table.concat(path_parts, '/')
            if path == "" then path = "/" end
            local entries = {}
            local cancel = fsutils.async_scan_dir(path, nil, nil,
                function(name, type)
                    local full_path = vim.fs.joinpath(path, name)
                    local is_dir = type == "directory"
                    table.insert(entries, {
                        label_chunks = {
                            { _get_icon(name, is_dir) },
                            { " " },
                            { name },
                        },
                        path_part = name,
                        supports_preview = not is_dir,
                        selectable = not is_dir
                    })
                end,
                function()
                    callback((entries))
                end)

            return cancel
        end
    }, function(path)
        if path then
            local filepath = table.concat(path, '/')
            uitools.smart_open_file(filepath)
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
