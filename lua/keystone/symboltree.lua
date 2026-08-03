local M = {}


---@class keystone.symboltree.Config
---@field width_ratio number?
---@field track_cursor boolean?  highlight/follow the symbol under the cursor
---@field auto_expand boolean?   expand every symbol on load
---@field show_detail boolean?   show the server-provided detail text
---@field exclude_kinds string[]? LSP symbol kind names to hide, e.g. { "Variable" }
---@field collapse_kinds string[]? LSP symbol kind names left collapsed on load
---                                even when `auto_expand` is set
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
        collapse_kinds = { "Function", "Method", "Object" },
        debounce_ms = 500,
    }
end

--- List-valued options a user supplies replace the default outright.
--- `vim.tbl_deep_extend` would otherwise merge them index by index, leaving
--- trailing defaults behind, e.g. { "Class" } over the default becoming
--- { "Class", "Method" }.
local _LIST_KEYS = { "exclude_kinds", "collapse_kinds" }

---@type keystone.symboltree.Config
M.config = _get_default_config()

---@param opts table?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
    for _, key in ipairs(_LIST_KEYS) do
        if opts and opts[key] then
            M.config[key] = vim.deepcopy(opts[key])
        end
    end

    require("keystone.util.usercmd").register_user_cmd("SymbolTree", function(cmd, args, opts)
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
