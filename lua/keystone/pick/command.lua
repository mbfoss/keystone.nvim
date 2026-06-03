local M = {}

local picker = require("keystone.pick.base.picker")

---@class keystone.PickerSpec
---@field prompt string
---@field flags keystone.queryflags.FlagDef[]?
---@field enable_preview boolean?
---@field preview_default "visible"|"hidden"|nil
---@field enable_list_sep boolean?
---@field height_ratio number?
---@field width_ratio number?
---@field list_wrap boolean?
---@field history_provider keystone.Picker.QueryHistoryProvider?
---@field quickfix_formatter (fun(data:any):vim.quickfix.entry?)?
---@field setup (fun(callback:fun(data:table?)))?
---@field finder fun(query:string, flags:table, fetch_opts:keystone.Picker.FetcherOpts, callback:fun(items:keystone.Picker.Item[]?), data:table?):fun()?
---@field previewer keystone.Picker.AsyncPreviewLoader?
---@field on_confirm fun(data:keystone.picker.ItemData?)

---@param spec keystone.PickerSpec
---@param data table?
local function _do_open(spec, data)
    picker.open({
        prompt             = spec.prompt,
        flags              = spec.flags,
        enable_preview     = spec.enable_preview,
        preview_default    = spec.preview_default,
        enable_list_sep    = spec.enable_list_sep,
        height_ratio       = spec.height_ratio,
        width_ratio        = spec.width_ratio,
        list_wrap          = spec.list_wrap,
        history_provider   = spec.history_provider,
        quickfix_formatter = spec.quickfix_formatter,
        previewer          = spec.previewer,
        finder             = function(query, flags, fetch_opts, callback)
            return spec.finder(query, flags, fetch_opts, callback, data)
        end,
    }, spec.on_confirm or function() end)
end

---@param spec keystone.PickerSpec?
local function _open_spec(spec)
    if not spec then return end
    if spec.setup then
        spec.setup(function(data)
            if data ~= nil then _do_open(spec, data) end
        end)
    else
        _do_open(spec, nil)
    end
end

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

local function _pick(picker_type)
    if not picker_type or picker_type == "" then
        local keys = vim.tbl_keys(_pickers)
        table.insert(keys, "repeat_last")
        table.sort(keys)
        vim.ui.select(keys, { prompt = "Pick" }, function(choice)
            if choice then _pick(choice) end
        end)
        return
    end

    if picker_type == "repeat_last" then
        picker.repeat_last()
        return
    end

    local factory = _pickers[picker_type]
    if factory then
        _open_spec(factory())
    else
        vim.notify("Invalid picker type: " .. tostring(picker_type), vim.log.levels.WARN)
    end
end

---@param cmd string
---@param rest string[]
---@return string[]
function M.get_subcommands(cmd, rest)
    if cmd == "Pick" and #rest == 0 then
        local keys = vim.tbl_keys(_pickers)
        table.insert(keys, "repeat_last")
        table.sort(keys)
        return keys
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
