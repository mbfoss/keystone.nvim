local M = {}

---@class keystone.explore.Config
---@field marks_persist_file (string | fun():string)?  -- nil = stdpath("data")/keystone.exploremarks.json

local function _get_default_config()
    ---@type keystone.explore.Config
    return {
        marks_persist_file = nil,
    }
end

---@type keystone.explore.Config
M.config = _get_default_config()

---@param opts keystone.explore.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
    require("keystone.explore.marks").setup(M.config.marks_persist_file)
    require("keystone.tk.usercmd").register_user_cmd("FileSelector", function(cmd, args, opts)
            require("keystone.explore.command").run_command(cmd, args, opts)
        end,
        {
            desc = "Explore",
            subcommand_fn = function(cmd, rest)
                return require("keystone.explore.command").get_subcommands(cmd, rest)
            end
        })
end

return M
