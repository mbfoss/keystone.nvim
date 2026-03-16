local M = {}

-- Define your pickers here.
-- The key is the subcommand name, and the value is a function that executes the picker.
local pickers = {
    recent_files         = function() require("keystone.pickers.oldfiles").open() end,
    lsp_references       = function() require("keystone.pickers.lsp").references() end,
    document_symbols     = function() require("keystone.pickers.lsp").document_symbols() end,
    document_functions   = function() require("keystone.pickers.lsp").document_functions() end,
    document_diagnostics = function() require("keystone.pickers.diagnosics").document_diagnostics() end,
    git_diff             = function() require("keystone.pickers.gitdiff").open() end,
}

local function _ensure_init()
    -- Logic for initialization if needed
end

local function _pick(picker_type)
    if not picker_type or picker_type == "" then
        return
    end

    local action = pickers[picker_type]
    if action then
        action()
    else
        vim.notify("Invalid picker type: " .. tostring(picker_type), vim.log.levels.WARN)
    end
end

---@return string[]
function M.get_commands()
    _ensure_init()
    return { "pick" }
end

---@param cmd string
---@param rest string[]
---@param for_cmd_menu boolean?
---@return string[]
function M.get_subcommands(cmd, rest, for_cmd_menu)
    _ensure_init()
    if cmd == "pick" then
        -- Automatically return all keys defined in the pickers table
        local keys = vim.tbl_keys(pickers)
        table.sort(keys)
        return keys
    end
    return {}
end

---@param cmd string
---@param rest string[]
---@param opts vim.api.keyset.create_user_command.command_args
function M.run_command(cmd, rest, opts)
    _ensure_init()
    if cmd == "pick" then
        _pick(rest[1])
    end
end

return M
