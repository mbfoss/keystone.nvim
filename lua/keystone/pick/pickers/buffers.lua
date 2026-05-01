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

    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local path
    if bufname ~= "" then
        path = fsutils.get_relative_path(vim.fn.fnamemodify(bufname, ":t")) or bufname
    else
        path = "[No Name]"
    end
    local modified = vim.bo[bufnr].modified
    local match = pickertools.match_label(path, query, { is_path = true, maxlen = list_width - (modified and 9 or 5) })
    if not match then return nil end

    local label_chunks = { { string.format("%3d",bufnr), "Comment" }, { ": ", "Nontext" } }
    vim.list_extend(label_chunks, match.chunks)
    if modified then
        table.insert(label_chunks, { " [+]", "Special" })
    end

    local mark = vim.api.nvim_buf_get_mark(bufnr, '"')
    local lnum, col = unpack(mark)
    ---@type keystone.Picker.Item
    return {
        label_chunks = label_chunks,
        score = match.score,
        data = { bufnr = bufnr, lnum = lnum, col = col, },
        filepath = vim.fn.fnamemodify(bufname, ":t"),
        lnum = lnum,
        col = col,
    }
end

function M.open()
    local buffers = vim.api.nvim_list_bufs()

    picker.open({
        prompt = "Open Buffers",
        enable_preview = true,
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
    }, function(data)
        if data then
            uitools.smart_open_buffer(data.bufnr, data.lnum, data.col)
        end
    end)
end

return M
