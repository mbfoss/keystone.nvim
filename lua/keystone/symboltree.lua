local M = {}


---@class keystone.symboltree.Config
---@field width_ratio number?
---@field track_cursor boolean?  highlight/follow the symbol under the cursor
---@field auto_expand boolean?   expand every symbol on load
---@field show_detail boolean?   show the server-provided detail text
---@field exclude_kinds string[]? LSP symbol kind names to hide, e.g. { "Variable" }
---@field debounce_ms integer?   edit-to-refresh delay

---@return keystone.symboltree.Config
local function _get_default_config()
    ---@type keystone.symboltree.Config
    return {
        width_ratio = 0.2,
        track_cursor = true,
        auto_expand = true,
        show_detail = true,
        exclude_kinds = nil,
        debounce_ms = 500,
    }
end

---@type keystone.symboltree.Config
M.config = _get_default_config()

---@param opts table?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

    require("keystone.tk.usercmd").register_user_cmd("SymbolTree", function(cmd, args, opts)
            require("keystone.symboltree.command").run_command(cmd, args, opts)
        end,
        {
            desc = "LSP symbol tree window",
            subcommand = function(cmd, rest)
                return require("keystone.symboltree.command").get_subcommands(cmd, rest)
            end
        })
end

return M
