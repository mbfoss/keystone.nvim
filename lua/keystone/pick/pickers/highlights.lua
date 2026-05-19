local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")

local M = {}

---@param name string
---@param hl table
---@param query string
---@param list_width number
---@return keystone.Picker.Item?
local function highlight_to_item(name, hl, query, list_width)
    if query ~= "" then
        local name_l = name:lower()
        local query_l = query:lower()
        if not name_l:find(query_l, 1, true) then
            return nil
        end
    end

    local chunks = { { name, name } }

    local link = hl.link
    if link then
        table.insert(chunks, { " → ", "Comment" })
        table.insert(chunks, { link, link })
    end

    return {
        label_chunks = chunks,
        data = { name = name },
    }
end

function M.open()
    local highlights = vim.api.nvim_get_hl(0, {})

    picker.open({
        prompt = "Highlights",
        enable_preview = false,

        finder = function(query, fetch_opts, callback)
            local items = {}

            for name, hl in pairs(highlights) do
                local item = highlight_to_item(name, hl, query, fetch_opts.list_width)
                if item then
                    table.insert(items, item)
                end
            end

            callback(items)
        end,
    }, function(data)
        if data then
            vim.api.nvim_put({ data.name }, "c", true, true)
        end
    end)
end

return M
