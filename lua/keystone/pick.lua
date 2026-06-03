local M = {}

local picker   = require("keystone.pick.base.picker")
local registry = require("keystone.pick.registry")

---@class keystone.pick.Config
---@field override_ui_select boolean?

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

local function _get_default_config()
    ---@type keystone.pick.Config
    return {
        override_ui_select = true,
    }
end

---@type keystone.pick.Config
M.config = _get_default_config()

---@param spec keystone.PickerSpec
---@param data table?
---@param initial_filter string?
local function _do_open(spec, data, initial_filter)
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
        initial_filter     = initial_filter,
        finder             = function(query, flags, fetch_opts, callback)
            return spec.finder(query, flags, fetch_opts, callback, data)
        end,
    }, spec.on_confirm or function() end)
end

---@param spec keystone.PickerSpec?
---@param initial_filter string?
local function _open_spec(spec, initial_filter)
    if not spec then return end
    if spec.setup then
        spec.setup(function(data)
            if data ~= nil then _do_open(spec, data, initial_filter) end
        end)
    else
        _do_open(spec, nil, initial_filter)
    end
end

---@param picker_type string?
---@param initial_filter string?
local function _pick(picker_type, initial_filter)
    if not picker_type or picker_type == "" then
        local keys = registry.keys()
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

    local spec = registry.get(picker_type)
    if spec then
        _open_spec(spec, initial_filter)
    else
        vim.notify("Invalid picker type: " .. tostring(picker_type), vim.log.levels.WARN)
    end
end

---@param opts keystone.pick.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

    require("keystone.util.usercmd").register_user_cmd("Pick",
        function(cmd, args)
            if cmd == "Pick" then
                local initial_filter = #args > 1 and table.concat(args, " ", 2) or nil
                _pick(args[1], initial_filter)
            end
        end,
        {
            desc = "Picker for files, grep etc...",
            subcommand_fn = function(cmd, rest)
                if cmd == "Pick" and #rest == 0 then
                    local keys = registry.keys()
                    table.insert(keys, "repeat_last")
                    table.sort(keys)
                    return keys
                end
                return {}
            end,
        })

    if M.config.override_ui_select then
        vim.ui.select = require("keystone.pick.select").select
    end
end

return M
