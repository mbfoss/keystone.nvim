local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local uitools = require("keystone.utils.uitools")
local fsutils = require("keystone.utils.fsutils")

local M = {}

---@param bufnr number
---@param query string
---@param list_width number
---@return keystone.Picker.Item?
local function buffer_to_picker_item(bufnr, query, list_width)
    if not vim.api.nvim_buf_is_loaded(bufnr) or not vim.bo[bufnr].buflisted then
        return nil
    end
    local label
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local path = fsutils.get_relative_path(vim.fn.fnamemodify(bufname, ":t")) or bufname
    local match, score, positions = pickertools.fuzzy_match(path, query, true)
    if not match then return nil end

    if bufname == "" then
        label = "[No Name]"
    else
        local suffix = vim.bo[bufnr].modified and " [+]" or ""
        local cropped = fsutils.smart_crop_path(path, list_width - #suffix)
        label = string.format("%d: %s%s", bufnr, cropped, suffix)
    end

    local label_chunks = pickertools.build_label_chunks()

    local mark = vim.api.nvim_buf_get_mark(bufnr, '"')
    local lnum, col = mark[1], nil ---@type number?,number?
    if lnum > 1 then col = mark[2] else lnum = nil end
    ---@type keystone.Picker.Item
    return {
        label = label,
        score = score,
        data = { filepath = vim.fn.fnamemodify(bufname, ":t"), bufnr = bufnr, lnum = lnum, col = col, }
    }
end

function M.open()
    local buffers = vim.api.nvim_list_bufs()

    picker.open({
        prompt = "Open Buffers",
        fetch = function(query, fetch_opts)
            local items = {}
            for _, bufnr in ipairs(buffers) do
                local item = buffer_to_picker_item(bufnr, query, fetch_opts.list_width)
                if item then
                    table.insert(items, item)
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
