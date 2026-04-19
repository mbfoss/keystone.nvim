local M = {}

local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")

---@return number,number
local function _compute_dimentions(items)
    local maxw, height = 0, 0
    for _, item in ipairs(items) do
        if item.label then
            maxw = math.max(maxw, vim.fn.strdisplaywidth(item.label))
            height = height + 1
        end
    end
    return maxw, height
end

function M.select(items, opts, on_choice)
    vim.validate("on_choice", on_choice, "function")
    opts = opts or {}

    local format_item = opts.format_item or function(item)
        return tostring(item)
    end

    -- cache formatted items once
    local cached = {}
    for i, item in ipairs(items) do
        local ok, label = pcall(format_item, item)
        if not ok then
            label = tostring(item)
        end
        cached[i] = {
            label = tostring(label),
            data = item,
        }
    end

    local list_width, list_height = _compute_dimentions(cached)
    local height_ratio = (list_height + 3) / vim.o.lines

    picker.select({
        prompt       = opts.prompt and opts.prompt:gsub("%s*:%s*$", "") or "Select item",
        file_preview = false,
        list_width   = list_width,
        height_ratio = height_ratio,
        fetch        = function(query, fetch_opts)
            local results = {}

            for _, entry in ipairs(cached) do
                local match = pickertools.make_picker_item(entry.label, query, {
                    list_width = fetch_opts.list_width,
                    is_path = false,
                })

                if match then
                    table.insert(results, {
                        label = entry.label,
                        data = entry.data,
                        label_chunks = match.chunks,
                    })
                end
            end

            return results
        end,
    }, function(choice)
        if choice then
            on_choice(choice)
        end
    end)
end

return M
