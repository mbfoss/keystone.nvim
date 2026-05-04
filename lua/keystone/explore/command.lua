local M = {}

local uv = vim.uv
local explorer = require("keystone.explore.explorer")

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
        --  enable_preview = true,
        fetch = function(current, direction, fetch_opts)
            local path

            if not current then
                path = uv.cwd()
            else
                path = current.path
                if direction == "out" then
                    path = vim.fn.fnamemodify(path, ":h:h")
                end
            end

            local entries = scandir(path)
            local result = {}

            for _, entry in ipairs(entries) do
                local full_path = path .. "/" .. entry.name

                local is_dir = entry.type == "directory"
                local prefix = is_dir and { " ", "Directory" } or { " " }
                table.insert(result, {
                    label_chunks = {
                        prefix,
                        { entry.name },
                    },
                    data = {
                        path = full_path,
                        is_dir = is_dir,
                    },
                })
            end

            return result
        end
    }, function(data)
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
