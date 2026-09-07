---@class keystone.icon.Data
---@field icon string
---@field color string
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

---@param group string
---@param color string
---@return nil
local function _set_hl(group, color)
    vim.api.nvim_set_hl(0, group, {
        fg = color,
    })
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

    for n, t in pairs(_types) do
        _set_hl("KeystoneIcons" .. n, t.color)
    end

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
