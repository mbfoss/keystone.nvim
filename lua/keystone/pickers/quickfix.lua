local picker = require('keystone.utils.picker')
local pickertools = require("keystone.utils.pickertools")
local uitools = require("keystone.utils.uitools")
local strtools = require("keystone.utils.strtools")

local M = {}

local function matches_filter(qf, filter)
    if filter == "all" or not filter then
        return true
    end
    local t = (qf.type or ""):upper()
    if filter == "errors" then
        return t == "E" or t == ""
    elseif filter == "warnings" then
        return t == "W"
    elseif filter == "info" then
        return t == "I"
    end
    return true
end

---@param item table Quickfix item from getqflist()
---@param list_width number
---@return table
local function qf_item_to_picker_item(item, list_width)
    local bufnr = item.bufnr
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    local display_path = strtools.smart_crop_path(vim.fn.fnamemodify(filepath, ":."), list_width)
    local prefix = ({
        E = " ",
        W = " ",
        I = " ",
    })[item.type] or ""

    local label = prefix .. vim.trim(item.text ~= "" and item.text or "[No description]")
    local virt_lines = nil
    if display_path and #display_path > 0 then
        virt_lines = { { { string.format("%s:%d:%d", display_path, item.lnum, item.col), "MoreMsg" } } }
    end
    return {
        label = label,
        virt_lines = virt_lines,
        data = {
            filepath = filepath,
            lnum = item.lnum,
            col = item.col > 0 and item.col - 1 or 0, -- Convert to 0-indexed if needed
            bufnr = bufnr
        }
    }
end

function M.open(opts)
    opts = opts or {}
    local filter = opts.filter or "all"
    local qflist = vim.fn.getqflist()

    local have_items = false
    for _, qf in ipairs(qflist) do
        if matches_filter(qf, filter) then
            have_items = true
        end
    end
    if not have_items then
        if filter == "all" then
            vim.notify("Quickfix list is empty", vim.log.levels.WARN)
        else
            vim.notify(("No %s in quickfix list"):format(filter), vim.log.levels.WARN)
        end
        return
    end

    picker.select({
        prompt = "Quickfix Items",
        file_preview = true,
        fetch = function(query, fetch_opts)
            local items = {}
            for _, qf in ipairs(qflist) do
                if matches_filter(qf, filter) then
                    local base_item = qf_item_to_picker_item(qf, fetch_opts.list_width)
                    local match = pickertools.make_picker_item(base_item.label, query, {
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
    }, function(data)
        if data then
            uitools.smart_open_file(data.filepath, data.lnum, data.col)
        end
    end)
end

return M
