local M = {}

local queryflags = require("keystone.pick.base.queryflags")

---@type keystone.queryflags.FlagDef[]
local FLAGS = {
    { name = "glob",   type = "value",   multi = true, desc = "raw glob pattern"    },
    { name = "file",   type = "value",   multi = true, desc = "filter by filename"  },
    { name = "dir",    type = "value",   multi = true, desc = "filter by directory" },
    { name = "regex",  type = "boolean",               desc = "enable regex mode"   },
    { name = "case",   type = "boolean",               desc = "case-sensitive"      },
    { name = "follow", type = "boolean",               desc = "follow symlinks"     },
}

---@return keystone.PickerSpec
function M.spec()
    return {
        prompt = "Parse Debug",
        flags  = FLAGS,
        finder = function(query, flags, _, callback)
            local items = {} ---@type keystone.Picker.Item[]

            items[#items + 1] = {
                label_chunks = {
                    { "query  ", "Keyword" },
                    { query ~= "" and query or "(empty)", query ~= "" and "String" or "Comment" },
                },
                data = {},
            }

            for name, val in pairs(flags) do
                local val_str
                if type(val) == "table" then
                    val_str = table.concat(val, ", ")
                elseif val == true then
                    val_str = "(set)"
                else
                    val_str = tostring(val)
                end
                items[#items + 1] = {
                    label_chunks = {
                        { "/" .. name .. "  ", "Keyword" },
                        { val_str, "String" },
                    },
                    data = {},
                }
            end

            callback(items)
        end,
        on_confirm = function() end,
    }
end

return M
