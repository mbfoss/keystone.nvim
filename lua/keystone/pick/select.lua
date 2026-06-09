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

---@generic T
---@param items T[] Arbitrary items
---@param opts table Additional options
---     - prompt (string|nil)
---               Text of the prompt. Defaults to `Select one of:`
---     - format_item (function item -> text)
---               Function to format an
---               individual item from `items`. Defaults to `tostring`.
---     - kind (string|nil)
---               Arbitrary hint string indicating the item shape.
---               Plugins reimplementing `vim.ui.select` may wish to
---               use this to infer the structure or semantics of
---               `items`, or the context in which select() was called.
---@param on_choice fun(item: T|nil, idx: integer|nil)
---               Called once the user made a choice.
---               `idx` is the 1-based index of `item` within `items`.
---               `nil` if the user aborted the dialog.
function M.select(items, opts, on_choice)
    vim.validate("on_choice", on_choice, "function")
    opts = opts or {}

    local format_item = opts.format_item or function(item)
        return tostring(item)
    end

    -- cache formatted items once
    local _cached = {}
    local _has_preview = false
    for i, item in ipairs(items) do
        local ok, label = pcall(format_item, item)
        if not ok then
            label = tostring(item)
        end
        if type(item) == "table" and item.preview ~= nil then
            _has_preview = true
        end
        _cached[i] = {
            label = tostring(label),
            data  = item,
        }
    end

    local list_width, list_height, height_ratio
    if not _has_preview then
        list_width, list_height = _compute_dimentions(_cached)
        height_ratio = (list_height + 3) / vim.o.lines
    end

    picker.open({
        prompt         = opts.prompt and opts.prompt:gsub("%s*:%s*$", "") or "Select",
        list_width     = list_width,
        height_ratio   = height_ratio,
        enable_preview = _has_preview,
        finder         = function(query, _, _, callback)
            local results = {}

            for _, entry in ipairs(_cached) do
                local match = pickertools.match_label(entry.label, query)
                if match then
                    -- do not set score, ui.select items should not be reordered
                    table.insert(results, {
                        label_chunks = match.chunks,
                        data         = entry.data,
                    })
                end
            end

            callback(results)
        end,

        previewer      = _has_preview and function(data, _, callback)
            local _p = type(data) == "table" and data.preview or nil
            if type(_p) == "string" then
                callback({ content = _p })
            elseif type(_p) == "table" and _p.filepath then
                pickertools.file_preview({ filepath = _p.filepath, lnum = _p.lnum, col = _p.col }, _, callback)
            else
                callback(nil)
            end
        end or nil,
    }, function(choice)
        if choice then
            on_choice(choice)
        end
    end)
end

return M
