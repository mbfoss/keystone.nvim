local M = {}


---@type fun(v:number,min:number,max:number):number
local function _clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

---@param opts {has_preview:boolean,height_ratio:number?,width_ratio:number?,list_width:number?}
---@return keystone.Explorer.Layout
function M.get_horizontal_layout(opts)
    local cols = vim.o.columns
    local lines = vim.o.lines

    local has_preview = opts.has_preview
    local spacing = has_preview and 2 or 0
    local half_spacing = math.floor(spacing / 2)

    local list_width = math.ceil(
        cols * _clamp(opts.width_ratio or 0.4, 0.1, 0.8)
    )

    local preview_width
    if has_preview then
        local width = math.min(list_width * 2, cols)
        preview_width = _clamp(
            width - list_width - half_spacing,
            1,
            width
        )
    else
        preview_width = 0
    end

    local height = math.ceil(
        lines * _clamp(opts.height_ratio or 0.7, 0.3, 0.9)
    )

    local total_width = list_width + preview_width + spacing

    local row = math.floor((lines - height) / 2)
    local col = math.floor((cols - total_width) / 2)

    return {
        list_row = row,
        list_col = col,
        list_width = list_width,
        list_height = height,

        preview_row = row,
        preview_col = col + list_width + spacing,
        preview_width = preview_width,
        preview_height = height,
    }
end

---@param opts {has_preview:boolean,height_ratio:number?,width_ratio:number?}
---@return keystone.Explorer.Layout
function M.get_vertical_layout(opts)
    local cols = vim.o.columns
    local lines = vim.o.lines

    local width = math.ceil(cols * _clamp(opts.width_ratio or 0.4, 0.1, 0.9))
    local total_height = math.ceil(lines * _clamp(opts.height_ratio or 0.6, 0.3, 0.95))

    local row = math.floor((lines - total_height) / 2)
    local col = math.floor((cols - width) / 2)

    if not opts.has_preview then
        return {
            list_row = row,
            list_col = col,
            list_width = width,
            list_height = total_height,

            preview_row = row,
            preview_col = col,
            preview_width = 0,
            preview_height = 0,
        }
    end

    -- split vertically: top=list, bottom=preview
    local spacing = 2
    local list_height = math.floor((total_height - spacing) / 3)
    local preview_height = total_height - list_height - spacing

    return {
        list_row = row,
        list_col = col,
        list_width = width,
        list_height = list_height,

        preview_row = row + list_height + spacing,
        preview_col = col,
        preview_width = width,
        preview_height = preview_height,
    }
end

return M
