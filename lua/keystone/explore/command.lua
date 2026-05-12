local M        = {}

local uv       = vim.uv
local explorer = require("keystone.explore.explorer")
local fsutils  = require("keystone.utils.fsutils")
local uitools  = require("keystone.utils.uitools")

local function scandir(path)
    local handle = uv.fs_scandir(path)
    if not handle then return {} end

    local items = {}
    while true do
        local name, type = uv.fs_scandir_next(handle)
        if not name then break end

        table.insert(items, {
            name = name,
            type = type, -- "file", "directory", etc.
        })
    end

    table.sort(items, function(a, b)
        -- directories first, then alphabetical
        if a.type ~= b.type then
            return a.type == "directory"
        end
        return a.name < b.name
    end)

    return items
end


local function _explore_files()
    explorer.open({
        prompt = "Explore",
        initial_path = vim.split(vim.fs.normalize(vim.fn.getcwd()), '/'),
        enable_preview = true,
        async_fetch = function(path_parts, fetch_opts, callback)
            if not path_parts then
                callback({})
                return function() end
            end
            local path = table.concat(path_parts, '/')
            local entries = {}
            local cancel = fsutils.async_scan_dir(path, nil, nil,
                function(name, type)
                    local full_path = vim.fs.joinpath(path, name)
                    local is_dir = type == "directory"
                    local prefix = is_dir and { " ", "Directory" } or { " " }
                    table.insert(entries, {
                        label_chunks = {
                            prefix,
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
    if cmd == "KeystoneExplore" then
        _explore_files()
    end
end

return M
