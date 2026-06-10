local M = {}

local picker      = require("keystone.pick.base.picker")
local pickertools  = require("keystone.pick.base.pickertools")

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

---@generic T
---@param items T[]
---@param opts table
---@param on_choice fun(item: T|nil, idx: integer|nil)
function M.select(items, opts, on_choice)
    vim.validate("on_choice", on_choice, "function")
    opts = opts or {}

    local format_item  = opts.format_item or tostring
    local preview_item = opts.preview_item ---@type (fun(item:any):{buf:integer?,pos:{[1]:integer,[2]:integer}?,pos_end:{[1]:integer,[2]:integer}?})?

    local _cached = {}
    for i, item in ipairs(items) do
        local ok, label = pcall(format_item, item)
        _cached[i] = {
            label = ok and tostring(label) or tostring(item),
            data  = item,
        }
    end

    local list_width, height_ratio
    if not preview_item then
        local list_height
        list_width, list_height = _compute_dimentions(_cached)
        height_ratio = (list_height + 3) / vim.o.lines
    end

    picker.open({
        prompt         = opts.prompt and opts.prompt:gsub("%s*:%s*$", "") or "Select",
        list_width     = list_width,
        height_ratio   = height_ratio,
        enable_preview = preview_item ~= nil,
        finder         = function(query, _, _, callback)
            local results = {}
            for _, entry in ipairs(_cached) do
                local match = pickertools.match_label(entry.label, query)
                if match then
                    table.insert(results, {
                        label_chunks = match.chunks,
                        data         = entry.data,
                    })
                end
            end
            callback(results)
        end,

        previewer = preview_item and function(data, _, callback)
            local result = preview_item(data)
            if not result or not result.buf then
                callback(nil)
                return
            end
            callback({
                bufnr   = result.buf,
                pos     = result.pos,
                pos_end = result.pos_end,
            })
        end or nil,
    }, function(choice)
        if not choice then
            on_choice(nil, nil)
            return
        end
        for i, item in ipairs(items) do
            if item == choice then
                on_choice(choice, i)
                return
            end
        end
        on_choice(choice, nil)
    end)
end

return M
