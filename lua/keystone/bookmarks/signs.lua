local _extmarks = require("keystone.bookmarks.extmarks")

local M = {}

---@class keystone.bookmarks.signs.SignInfo
---@field id number
---@field file string
---@field name string
---@field lnum number
---@field priority number
---@field user_data any
---@field source "live"|"stored"

---@class keystone.bookmarks.signs.Group
---@field define_sign fun(name:string, text:string, texthl:string)
---@field set_file_sign fun(id:number, file:string, lnum:number, name:string, user_data:any)
---@field remove_sign fun(id:number)
---@field remove_file_signs fun(file:string)
---@field remove_signs fun()
---@field get_signs fun(live:boolean): keystone.bookmarks.signs.SignInfo[]
---@field get_file_signs fun(file:string, live:boolean): keystone.bookmarks.signs.SignInfo[]
---@field get_sign_by_location fun(file:string, lnum:number, live:boolean): keystone.bookmarks.signs.SignInfo?
---@field get_sign_by_id fun(id:number): keystone.bookmarks.signs.SignInfo?
---@field refresh fun()

---@param group string
---@param opts { priority: number }
---@return keystone.bookmarks.signs.Group
function M.define_group(group, opts)
    assert(group, "group required")
    assert(opts and opts.priority, "priority required")

    local _priority = opts.priority
    local _sign_defs = {} ---@type table<string, { text:string, texthl:string }>

    local _ext = _extmarks.define_group(group, { priority = _priority })

    local function _convert_mark(mark)
        if not mark then return nil end
        local user = mark.user_data
        if not user or not user.name then return nil end
        return {
            id        = mark.id,
            file      = mark.file,
            name      = user.name,
            lnum      = mark.lnum,
            priority  = _priority,
            user_data = user.user_data,
            source    = mark.source,
        }
    end

    ---@type keystone.bookmarks.signs.Group
    return {
        define_sign = function(name, text, texthl)
            assert(name and text and texthl, "invalid sign definition")
            assert(not _sign_defs[name], "sign already defined: " .. name)
            _sign_defs[name] = { text = text, texthl = texthl }
        end,

        set_file_sign = function(id, file, lnum, name, user_data)
            local def = _sign_defs[name]
            assert(def, "sign not defined: " .. tostring(name))
            assert(lnum >= 1, "lnum must be 1-based")
            _ext.set_file_extmark(id, file, lnum, 0, {
                sign_text     = def.text,
                sign_hl_group = def.texthl,
            }, {
                name      = name,
                user_data = user_data,
            })
        end,

        remove_sign = function(id)
            _ext.remove_extmark(id)
        end,

        remove_file_signs = function(file)
            _ext.remove_file_extmarks(file)
        end,

        remove_signs = function()
            _ext.remove_extmarks()
        end,

        get_signs = function(live)
            local marks = _ext.get_extmarks(live)
            ---@type keystone.bookmarks.signs.SignInfo[]
            local result = {}
            for _, mark in ipairs(marks) do
                local sign = _convert_mark(mark)
                if sign then result[#result + 1] = sign end
            end
            return result
        end,

        get_file_signs = function(file, live)
            local marks = _ext.get_file_extmarks(file, live)
            ---@type keystone.bookmarks.signs.SignInfo[]
            local result = {}
            for _, mark in ipairs(marks) do
                local sign = _convert_mark(mark)
                if sign then result[#result + 1] = sign end
            end
            return result
        end,

        get_sign_by_location = function(file, lnum, live)
            local mark = _ext.get_extmark_by_location(file, lnum, live)
            return _convert_mark(mark)
        end,

        get_sign_by_id = function(id)
            local mark = _ext.get_extmark_by_id(id)
            return _convert_mark(mark)
        end,

        refresh = function()
            _ext.refresh()
        end,
    }
end

return M
