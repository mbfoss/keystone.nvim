local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local uitools = require("keystone.utils.uitools")
local fsutils = require("keystone.utils.fsutils")

local M = {}

---@param bufnr number
---@param list_width number
---@return keystone.Picker.Item?
local function buffer_to_picker_item(bufnr, list_width)
    if not vim.api.nvim_buf_is_loaded(bufnr) or not vim.bo[bufnr].buflisted then
        return nil
    end

    local filepath = vim.api.nvim_buf_get_name(bufnr)
    local name = filepath ~= "" and vim.fn.fnamemodify(filepath, ":t") or "[No Name]"
    local relative_path = fsutils.get_relative_path(filepath) or filepath
    local modified = vim.bo[bufnr].modified and " [+]" or ""
    local label = string.format("%d: %s%s", bufnr, name, modified)

    local display_path = fsutils.smart_crop_path(relative_path, list_width)
    local virt_lines
    if display_path ~= "" and display_path ~= name then
        virt_lines = { { { display_path, "Special" } } }
    end
    local mark = vim.api.nvim_buf_get_mark(bufnr, '"')
    local lnum, col = mark[1], nil ---@type number?,number?
    if lnum > 1 then col = mark[2] else lnum = nil end
    ---@type keystone.Picker.Item
    return {
        label = label,
        virt_lines = virt_lines,
        data = { filepath = filepath, bufnr = bufnr, lnum = lnum, col = col, }
    }
end

function M.open()
    local buffers = vim.api.nvim_list_bufs()

    picker.select({
        prompt = "Open Buffers",
        file_preview = true,
        fetch = function(query, fetch_opts)
            local items = {}
            for _, bufnr in ipairs(buffers) do
                local base_item = buffer_to_picker_item(bufnr, fetch_opts.list_width)
                if base_item then
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
            uitools.smart_open_buffer(data.bufnr, data.lnum, data.col)
        end
    end)
end

return M
