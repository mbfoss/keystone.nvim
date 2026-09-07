local M = {}


---@type fun(v:number,min:number,max:number):number
local function _clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

-- A bordered float is anchored at its top-left corner, so it covers width + 2 by
-- height + 2 cells. Centring has to measure that footprint, not the inner size.
local _BORDER = 2

--- The band a float can be centred in: everything but the command line and, when one
--- is shown, the tab line.
---@return number top, number height
local function _editor_band()
    local top = 0
    if vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1) then
        top = 1
    end
    return top, vim.o.lines - vim.o.cmdheight - top
end

---@param opts {has_preview:boolean,height_ratio:number?,width_ratio:number?,list_width:number?}
---@return keystone.Explorer.Layout
function M.get_horizontal_layout(opts)
    local cols = vim.o.columns
    local lines = vim.o.lines

    local has_preview = opts.has_preview
    local spacing = has_preview and _BORDER or 0

    -- Both floats have to fit side by side, borders included.
    local list_width = _clamp(
        math.ceil(cols * _clamp(opts.width_ratio or 0.4, 0.1, 0.8)),
        1,
        has_preview and (cols - _BORDER * 2 - 1) or (cols - _BORDER)
    )

    local preview_width
    if has_preview then
        local width = math.min(list_width * 2 + _BORDER * 2, cols)
        preview_width = math.max(width - list_width - _BORDER * 2, 1)
    else
        preview_width = 0
    end

    local band_top, band_height = _editor_band()
    local height = _clamp(
        math.ceil(lines * _clamp(opts.height_ratio or 0.7, 0.3, 0.9)),
        1,
        band_height - _BORDER
    )

    local total_width = list_width + preview_width + spacing + _BORDER

    local row = band_top + math.floor((band_height - (height + _BORDER)) / 2)
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
