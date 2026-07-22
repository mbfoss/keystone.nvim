local M        = {}

---@class keystone.pick.Config
---@field override_ui_select boolean?
---@field auto_complete_flags boolean? Auto-open flag completion while typing (default true).

---@class keystone.PickerSpec
---@field prompt string
---@field flags keystone.queryflags.FlagDef[]?
---@field enable_preview boolean?
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
        override_ui_select  = true,
        auto_complete_flags = true,
    }
end

---@type keystone.pick.Config
M.config = _get_default_config()

---The most recent picker invocation, replayed by M.repeat_last(). Holds the
---resolved spec and its setup data so repeat reopens without re-running setup,
---plus the final prompt text so the same query is restored.
---@type {spec:keystone.PickerSpec, data:table?, query:string, index:integer?, items:keystone.Picker.Item[]?}?
local _last_pick = nil

---@param spec keystone.PickerSpec
---@param data table?
---@param initial_query string?
---@param initial_index integer?
---@param replay_items keystone.Picker.Item[]? Cached results to seed the first fetch instead of re-running the finder.
local function _do_open(spec, data, initial_query, initial_index, replay_items)
    local picker = require("keystone.pick.base.picker")
    _last_pick = { spec = spec, data = data, query = initial_query or "", index = initial_index, items = replay_items }
    local replayed = false
    picker.open({
        prompt             = spec.prompt,
        flags              = spec.flags,
        enable_preview     = spec.enable_preview,
        enable_list_sep    = spec.enable_list_sep,
        height_ratio       = spec.height_ratio,
        width_ratio        = spec.width_ratio,
        list_wrap          = spec.list_wrap,
        history_provider   = spec.history_provider,
        quickfix_formatter = spec.quickfix_formatter,
        previewer          = spec.previewer,
        initial_query      = initial_query,
        initial_index      = initial_index,
        auto_complete_flags = M.config.auto_complete_flags,
        finder             = function(query, flags, fetch_opts, callback)
            -- Serve the cached snapshot for the first (unchanged) query so a
            -- repeated picker opens instantly; any edit falls through to a fresh
            -- finder run.
            if replay_items and not replayed then
                replayed = true
                callback(replay_items)
                return nil
            end
            -- Keep a reference to each fresh result set as it flows to the picker,
            -- capped, so repeat_last can replay it without re-running the finder.
            return spec.finder(query, flags, fetch_opts, function(items)
                if _last_pick and _last_pick.spec == spec then
                    _last_pick.items = items
                end
                callback(items)
            end, data)
        end,
        on_close           = function(query, index)
            -- Remember the final query and highlighted row so repeat_last restores
            -- both.
            if _last_pick and _last_pick.spec == spec then
                _last_pick.query = query
                _last_pick.index = index
            end
        end,
    }, spec.on_confirm or function() end)
end

--- Reopen the most recent picker with its last query. Reuses the resolved spec
--- and setup data, so setup is not run again.
function M.repeat_last()
    if not _last_pick then
        vim.notify("No previous picker session", vim.log.levels.INFO)
        return
    end
    _do_open(_last_pick.spec, _last_pick.data, _last_pick.query, _last_pick.index, _last_pick.items)
end

---@param spec keystone.PickerSpec?
---@param initial_query string?
local function _open_spec(spec, initial_query)
    if not spec then return end
    if spec.setup then
        spec.setup(function(data)
            if data ~= nil then _do_open(spec, data, initial_query) end
        end)
    else
        _do_open(spec, nil, initial_query)
    end
end

---@param picker_type string?
---@param initial_query string?
function M.pick(picker_type, initial_query)
    local registry    = require("keystone.pick.registry")
    local pickertools = require("keystone.pick.base.pickertools")
    if not picker_type or picker_type == "" then
        local keys = registry.keys()
        table.insert(keys, "repeat_last")
        table.sort(keys)
        vim.ui.select(keys, { prompt = "Pick" }, function(choice)
            if choice then M.pick(choice) end
        end)
        return
    end

    if picker_type == "repeat_last" then
        M.repeat_last()
        return
    end

    local spec = registry.get(picker_type)
    if spec then
        spec.history_provider = spec.history_provider or pickertools.make_history_provider(picker_type)
        _open_spec(spec, initial_query)
    elseif not registry.has(picker_type) then
        vim.notify("Invalid picker type: " .. tostring(picker_type), vim.log.levels.WARN)
    end
end

---@param name string
---@param spec keystone.PickerSpec | fun(): keystone.PickerSpec?
function M.register(name, spec)
    require("keystone.pick.registry").register(name, spec)
end

---@param opts keystone.pick.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

    vim.api.nvim_set_hl(0, "KeystonePickMatch", { default = true, link = "Label" })
    vim.api.nvim_set_hl(0, "KeystonePickPath", { default = true, link = "@namespace" })
    vim.api.nvim_set_hl(0, "KeystonePickBufferIndicator", { default = true, link = "Special" })

    vim.api.nvim_create_user_command("Pick", function(cmd_opts)
        local picker_type   = cmd_opts.fargs[1]
        local initial_query = #cmd_opts.fargs > 1 and cmd_opts.args:match("^%S+%s+(.+)$") or nil
        M.pick(picker_type, initial_query)
    end, {
        nargs    = "*",
        desc     = "Picker for files, grep etc...",
        complete = function(arg_lead, cmd_line, _)
            local registry = require("keystone.pick.registry")
            local parts    = vim.split(cmd_line, "%s+", { trimempty = true })
            if #parts <= 1 or (#parts == 2 and not cmd_line:match("%s$")) then
                local keys = registry.keys()
                table.insert(keys, "repeat_last")
                table.sort(keys)
                return vim.tbl_filter(function(k) return vim.startswith(k, arg_lead) end, keys)
            end
            local flags = registry.get_flags(parts[2])
            if not flags then return {} end
            local out = {}
            for _, flag in ipairs(flags) do
                if flag.type == "boolean" then
                    table.insert(out, flag.name)
                else
                    table.insert(out, flag.name .. ":")
                end
            end
            return vim.tbl_filter(function(v) return vim.startswith(v, arg_lead) end, out)
        end,
    })

    if M.config.override_ui_select then
        vim.ui.select = require("keystone.pick.select").select
    end
end

return M
