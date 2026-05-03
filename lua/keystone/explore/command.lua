local M = {}

local explorer = require("keystone.explore.explorer")
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
        explorer.open({
            prompt = "Explore",
          --  enable_preview = true,
            fetch = function(query, fetch_opts)
                return {
                    { label_chunks = { { "Test1" } }, data = {} },
                    { label_chunks = { { "Test2" } }, data = {} }
                }
            end
        }, function(data)

        end)
    end
end

return M
