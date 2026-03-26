local picker = require('keystone.utils.picker')
local pickertools = require("keystone.utils.pickertools")
local uitools = require("keystone.utils.uitools")
local strtools = require("keystone.utils.strtools")

local M = {}

---@param item table Quickfix item from getqflist()
---@param list_width number
---@return table
local function qf_item_to_picker_item(item, list_width)
    local bufnr = item.bufnr
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    local display_path = strtools.smart_crop_path(vim.fn.fnamemodify(filepath, ":."), list_width)
    
    -- The text shown in the picker is the error message/description
    local label = vim.trim(item.text ~= "" and item.text or "[No description]")

    return {
        label = label,
        -- Use virt_lines to show the location like your LSP pattern
        virt_lines = { 
            { 
                { string.format("%s:%d:%d", display_path, item.lnum, item.col), "Comment" } 
            } 
        },
        data = {
            filepath = filepath,
            lnum = item.lnum,
            col = item.col > 0 and item.col - 1 or 0, -- Convert to 0-indexed if needed
            bufnr = bufnr
        }
    }
end

function M.open()
    local qflist = vim.fn.getqflist()
    
    if vim.tbl_isempty(qflist) then
        vim.notify("Quickfix list is empty", vim.log.levels.WARN)
        return
    end

    picker.select({
        prompt = "Quickfix Items",
        file_preview = true,
        fetch = function(query, fetch_opts)
            local items = {}
            for _, qf in ipairs(qflist) do
                if qf.valid == 1 then
                    local base_item = qf_item_to_picker_item(qf, fetch_opts.list_width)

                    -- Use make_picker_item to fuzzy search the 'text' of the quickfix
                    local match = pickertools.make_picker_item(base_item.label, query, base_item.label, {
                        list_width = fetch_opts.list_width,
                        is_path = false
                    })

                    if match then
                        base_item.label_chunks = match.chunks
                        base_item.score = match.score
                        table.insert(items, base_item)
                    end
                end
            end
            
            table.sort(items, function(a, b) return a.score > b.score end)
            return items
        end,
        async_preview = function(data, _, callback)
            return pickertools.default_file_preview(data.filepath, {
                lnum = data.lnum,
                col = data.col
            }, callback)
        end,
    }, function(selected)
        if selected then
            uitools.smart_open_file(selected.data.filepath, selected.data.lnum, selected.data.col)
        end
    end)
end

return M