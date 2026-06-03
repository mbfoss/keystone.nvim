local M = {}

---@type table<string, fun(): keystone.PickerSpec?>
local _pickers = {
    files                 = function() return require("keystone.pick.pickers.files").spec() end,
    live_grep             = function() return require("keystone.pick.pickers.livegrep").spec() end,
    recent_files          = function() return require("keystone.pick.pickers.recentfiles").spec() end,
    config_files          = function()
        return require("keystone.pick.pickers.files").spec({
            cwd    = vim.fn.stdpath("config"),
            prompt = "Config files",
        })
    end,
    quickfix              = function() return require("keystone.pick.pickers.quickfix").spec() end,
    jumplist              = function() return require("keystone.pick.pickers.jumplist").spec() end,
    lsp_references        = function() return require("keystone.pick.pickers.lsp").references_spec() end,
    document_symbols      = function() return require("keystone.pick.pickers.lsp").document_symbols_spec() end,
    document_diagnostics  = function() return require("keystone.pick.pickers.diagnosics").spec({ bufnr = 0 }) end,
    workspace_diagnostics = function() return require("keystone.pick.pickers.diagnosics").spec() end,
    git_diff              = function() return require("keystone.pick.pickers.git_diff").spec() end,
    buffers               = function() return require("keystone.pick.pickers.buffers").spec() end,
    all_buffers           = function()
        return require("keystone.pick.pickers.buffers").spec({
            include_unloaded = true,
            include_unlisted = true,
        })
    end,
    windows               = function() return require("keystone.pick.pickers.windows").spec() end,
    spell_suggest         = function() return require("keystone.pick.pickers.spell").spec() end,
    highlights            = function() return require("keystone.pick.pickers.highlights").spec() end,
    autocommands          = function() return require("keystone.pick.pickers.autocommands").spec() end,
    keymaps               = function() return require("keystone.pick.pickers.keymaps").spec() end,
    notifications         = function() return require("keystone.pick.pickers.notifications").spec() end,
    commands              = function() return require("keystone.pick.pickers.commands").spec() end,
}

---@return string[]
function M.keys()
    return vim.tbl_keys(_pickers)
end

---@param name string
---@return keystone.PickerSpec?
function M.get(name)
    local factory = _pickers[name]
    return factory and factory() or nil
end

---@param name string
---@return keystone.queryflags.FlagDef[]?
function M.get_flags(name)
    local spec = M.get(name)
    return spec and spec.flags or nil
end

return M
