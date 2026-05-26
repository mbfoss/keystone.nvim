local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")

local M = {}

local modes = { "n", "i", "v", "x", "s", "o", "c", "t" }

local function format_lhs(lhs)
    if not lhs then return "" end

    return lhs
        :gsub(" ", "<space>")
        :gsub("\t", "<tab>")
end

---@param km vim.api.keyset.get_keymap
---@return string
local function format_preview(km)
    local function fmt(val)
        if val == nil or val == 0 then return nil end
        if val == 1 then return "true" end
        return tostring(val)
    end

    local function add(lines, label, value)
        local v = fmt(value)
        if v and v ~= "" then
            table.insert(lines, string.format("- %s: %s", label, v))
        end
    end

    local lines = {}

    add(lines, "Mode", km.mode)
    add(lines, "LHS", km.lhs)
    add(lines, "Description", km.desc)
    add(lines, "RHS", km.rhs)
    add(lines, "Buffer", km.buffer)
    add(lines, "Abbreviation", km.abbr)
    add(lines, "NoRemap", km.noremap)
    add(lines, "Nowait", km.nowait)
    add(lines, "Silent", km.silent)
    add(lines, "Script", km.script)
    add(lines, "Expr", km.expr)
    add(lines, "SID", km.sid)
    add(lines, "Line", km.lnum)

    table.insert(lines, "")
    table.insert(lines, "Action:")

    if km.callback then
        local info = debug.getinfo(km.callback, "S")
        table.insert(lines, "- Type: Lua callback")
        if info then
            if info.short_src then
                table.insert(lines, string.format("- Source: `%s`", info.short_src))
            end
            if info.linedefined and info.linedefined > 0 then
                table.insert(lines, string.format("- Start Line: %d", info.linedefined))
            end
        end
    elseif km.rhs and km.rhs ~= "" then
        table.insert(lines, "- Type: Vim Command / Mapping")
    else
        table.insert(lines, "_No action defined_")
    end

    return table.concat(lines, "\n")
end

function M.open()
    ---@type vim.api.keyset.get_keymap[]
    local entries = {}

    -- collect all modes
    for _, mode in ipairs(modes) do
        local global = vim.api.nvim_get_keymap(mode)
        for _, km in ipairs(global) do
            km.mode = mode
            table.insert(entries, km)
        end
        local buf = vim.api.nvim_get_current_buf()
        local bufmaps = vim.api.nvim_buf_get_keymap(buf, mode)
        for _, km in ipairs(bufmaps) do
            km.mode = mode
            km.buffer = buf
            table.insert(entries, km)
        end
    end

    if vim.tbl_isempty(entries) then
        vim.notify("No keymaps found", vim.log.levels.WARN)
        return
    end

    picker.open({
            prompt = "Keymaps",
            enable_preview = true,
            finder = function(query, _, fetch_opts, callback)
                local items = {}

                for _, km in ipairs(entries) do
                    local label = string.format(
                        "%s │ %-9s │ %s",
                        km.mode or "",
                        format_lhs(km.lhs or ""),
                        (km.desc and km.desc ~= "") and km.desc or (km.rhs or "")
                    )
                    local match = pickertools.match_label(label, query)
                    if match then
                        table.insert(items, {
                            label_chunks = match.chunks,
                            score = match.score,
                            data = { km = km },
                        })
                    end
                end

                table.sort(items, function(a, b)
                    return a.score > b.score
                end)

                callback(items)
            end,
            previewer = function(data, opts, callback)
                callback({
                    content = format_preview(data.km),
                })
                return function() end
            end
        },
        function(item)
            if not item then return end
        end)
end

return M
