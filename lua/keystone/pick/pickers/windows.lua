local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")

local M = {}

---@param winid number
---@param query string
---@return keystone.Picker.Item?
local function window_to_picker_item(winid, query)
    if not vim.api.nvim_win_is_valid(winid) then return nil end

    local bufnr = vim.api.nvim_win_get_buf(winid)
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local filename = bufname ~= "" and vim.fn.fnamemodify(bufname, ":t") or "[No Name]"

    local match = pickertools.match_label(filename, query)
    if not match then return nil end

    local label_chunks = {
        { string.format("%2d ", winid),                               "Comment" },
        { string.format("[%d] ", vim.api.nvim_win_get_number(winid)), "Constant" }
    }
    vim.list_extend(label_chunks, match.chunks)

    local filetype = vim.bo[bufnr].filetype
    if filetype ~= "" then
        table.insert(label_chunks, { " <" .. filetype .. ">", "Type" })
    end

    local cursor = vim.api.nvim_win_get_cursor(winid)

    ---@type keystone.Picker.Item
    return {
        label_chunks = label_chunks,
        score = match.score,
        data = {
            winid = winid,
            bufnr = bufnr,
            lnum = cursor[1],
            col = cursor[2]
        },
    }
end

---@param opts {only_current_tab:boolean?}?
function M.open(opts)
    opts = opts or {}
    local windows = opts.only_current_tab and vim.api.nvim_tabpage_list_wins(0) or vim.api.nvim_list_wins()

    picker.open({
        prompt = "Switch Window",
        enable_preview = true,
        fetch = function(query)
            local items = {}
            for _, winid in ipairs(windows) do
                local config = vim.api.nvim_win_get_config(winid)
                if config.relative == "" then
                    local item = window_to_picker_item(winid, query)
                    if item then
                        table.insert(items, item)
                    end
                end
            end
            return items
        end,
        async_preview = function(data, _, callback)
            local bufnr = data.bufnr
            local cancelled = false
            vim.schedule(function()
                if not cancelled and vim.api.nvim_buf_is_valid(bufnr) then
                    callback({
                        content = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
                        filetype = vim.bo[bufnr].filetype,
                    })
                else
                    callback({})
                end
            end)
            return function() cancelled = true end
        end,
    }, function(data)
        if data and vim.api.nvim_win_is_valid(data.winid) then
            vim.api.nvim_set_current_win(data.winid)
        end
    end)
end

return M
