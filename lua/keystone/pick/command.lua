local M = {}

local pickers = {
    files                 = function() require("keystone.pick.pickers.files").open() end,
    live_grep             = function() require("keystone.pick.pickers.livegrep").open() end,
    recent_files          = function() require("keystone.pick.pickers.recentfiles").open() end,
    config_files          = function()
        require("keystone.pick.pickers.files").open({
            cwd = vim.fn.stdpath("config"),
            prompt =
            "Config files"
        })
    end,
    quickfix              = function() require("keystone.pick.pickers.quickfix").open() end,
    lsp_references        = function() require("keystone.pick.pickers.lsp").references() end,
    document_symbols      = function() require("keystone.pick.pickers.lsp").document_symbols() end,
    document_functions    = function() require("keystone.pick.pickers.lsp").document_functions() end,
    document_diagnostics  = function() require("keystone.pick.pickers.diagnosics").open({ bufnr = 0 }) end,
    workspace_diagnostics = function() require("keystone.pick.pickers.diagnosics").open() end,
    git_diff              = function() require("keystone.pick.pickers.git_diff").open() end,
    git_hunks             = function() require("keystone.pick.pickers.git_hunks").open({ current_file = true }) end,
    buffers               = function() require("keystone.pick.pickers.buffers").open() end,
    spell_suggest         = function() require("keystone.pick.pickers.spell").open() end,
}

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

---@param cmd string
---@param rest string[]
---@param for_cmd_menu boolean?
---@return string[]
function M.get_subcommands(cmd, rest, for_cmd_menu)
    if cmd == "Pick" then
        if #rest == 0 then
            local keys = vim.tbl_keys(pickers)
            table.sort(keys)
            return keys
        end
    end
    return {}
end

---@param cmd string
---@param args string[]
---@param opts vim.api.keyset.create_user_command.command_args
function M.run_command(cmd, args, opts)
    if cmd == "Pick" then
        _pick(args[1])
    end
end

return M
