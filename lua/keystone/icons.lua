---@class keystone.icon.Data
---@field icon string
---@field color1 string dark-mode (Catppuccin Mocha inspired) hex color
---@field color2 string light-mode (Catppuccin Latte inspired) hex color
---@field name string

---@class keystone.icon.Module
---@field ready boolean
---@field native boolean
---@field devicons table|nil
---@field icons table<string, keystone.icon.Data>
---@field filenames table<string, keystone.icon.Data>
local M = {}

local _ready
local _types
local _extensions
local _filenames

local _AUGROUP = "keystone_icons"

---@param group string
---@param color string
---@return nil
local function _set_hl(group, color)
    vim.api.nvim_set_hl(0, group, {
        fg = color,
    })
end

---Colors are hardcoded, so the groups only need reinstating, not recomputing:
---`:colorscheme` clears every global group, which would otherwise leave the
---icons unhighlighted for the rest of the session. `color1` is the dark
---palette, `color2` the light one, picked from `background`.
---@return nil
local function _apply_hl()
    assert(_types)
    local light = vim.o.background == "light"
    for n, t in pairs(_types) do
        _set_hl("KeystoneIcons" .. n, light and t.color2 or t.color1)
    end
end

---@return nil
local function _init()
    if _ready then
        return
    end
    local data = require("keystone.icon.data")

    assert(not _types and not _extensions and not _filenames)
    _types = data.get_types()
    _extensions = data.get_extensions()
    _filenames = data.get_filenames()

    _apply_hl()

    vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup(_AUGROUP, { clear = true }),
        callback = _apply_hl,
    })
    vim.api.nvim_create_autocmd("OptionSet", {
        group = _AUGROUP,
        pattern = "background",
        callback = _apply_hl,
    })

    _ready = true
end

---@param filename? string
---@param extension? string
---@param opts? table
---@return string, string
function M.get_icon(filename, extension, opts)
    if not _ready then
        _init()
        assert(_ready)
    end

    local type = filename and _filenames[filename] or nil
    if not type then
        if extension then
            type = _extensions[extension]
        elseif filename then
            extension = filename:match("%.([^.]+)$")
            if extension then
                type = _extensions[extension]
            end
        end
    end

    local data = type and _types[type] or nil

    if not data then
        return "", "Normal"
    end

    return data.icon, "KeystoneIcons" .. data.name
end

return M
