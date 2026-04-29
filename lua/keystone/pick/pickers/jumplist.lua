local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local uitools = require("keystone.utils.uitools")
local fsutils = require("keystone.utils.fsutils")

local M = {}

local function jump_item_to_picker_item(item)
    local bufnr = item.bufnr
    if not bufnr or bufnr == 0 then return nil end
    if not vim.api.nvim_buf_is_valid(bufnr) then return nil end
    local name = vim.api.nvim_buf_get_name(bufnr)
    local display = name ~= "" and name or "[No Name]"
    return {
        label = string.format(
            "%s:%d:%d",
            display,
            item.lnum or 0,
            item.col or 0
        ),
        data = {
            filepath = name,
            lnum = item.lnum,
            col = (item.col or 1) - 1,
            bufnr = bufnr,
        }
    }
end

function M.open()
    local jumplist, _ = unpack(vim.fn.getjumplist())

    if not jumplist or vim.tbl_isempty(jumplist) then
        vim.notify("Jumplist is empty", vim.log.levels.WARN)
        return
    end

    picker.open({
        prompt = "Jumplist",
        file_preview = true,

        fetch = function(query, fetch_opts)
            local items = {}
            for jump_i = #jumplist, 1, -1 do
                local base_item = jump_item_to_picker_item(jumplist[jump_i])
                if base_item then
                    local match = pickertools.make_picker_item(base_item.label, query, {
                        list_width = fetch_opts.list_width,
                        is_path = true
                    })
                    if match then
                        base_item.label_chunks = match.chunks
                        base_item.score = match.score
                        table.insert(items, base_item)
                    end
                end
            end
            return items
        end,

        async_preview = function(data, _, callback)
            return pickertools.default_file_preview(data.filepath, {
                lnum = data.lnum,
                col = data.col
            }, callback)
        end,
    }, function(data)
        if data then
            uitools.smart_open_file(data.filepath, data.lnum, data.col)
        end
    end)
end

return M
