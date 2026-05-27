local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")

local M = {}

---@type keystone.queryflags.FlagDef[]
local FLAGS = {
    { name = "float",  type = "boolean", desc = "include floating windows" },
    { name = "hidden", type = "boolean", desc = "include hidden buffers"   },
}

---@param winid number
---@param query string
---@param is_float boolean
---@return keystone.Picker.Item?
local function window_to_picker_item(winid, query, is_float, current_win)
    if not vim.api.nvim_win_is_valid(winid) then return nil end

    local bufnr = vim.api.nvim_win_get_buf(winid)
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local filename = bufname ~= "" and vim.fn.fnamemodify(bufname, ":t") or "[No Name]"

    local match = pickertools.match_label(filename, query)
    if not match then return nil end

    local label_chunks = {
        { string.format("%2d ", winid),                               "Comment" },
        { string.format("[%d] ", vim.api.nvim_win_get_number(winid)), "Constant" },
    }
    vim.list_extend(label_chunks, match.chunks)

    local filetype = vim.bo[bufnr].filetype
    if filetype ~= "" then
        table.insert(label_chunks, { "  " .. filetype, "Comment" })
    end
    if is_float then
        table.insert(label_chunks, { " [float]", "Special" })
    end
    if not vim.bo[bufnr].buflisted then
        table.insert(label_chunks, { " [hidden]", "Special" })
    end

    local cursor = vim.api.nvim_win_get_cursor(winid)

    ---@type keystone.Picker.Item
    return {
        label_chunks = label_chunks,
        score        = match.score,
        data         = { winid = winid, bufnr = bufnr, lnum = cursor[1], col = cursor[2] },
        initial      = winid == current_win or nil,
    }
end

---@param opts {only_current_tab:boolean?}?
function M.open(opts)
    opts = opts or {}
    local windows     = opts.only_current_tab and vim.api.nvim_tabpage_list_wins(0) or vim.api.nvim_list_wins()
    local current_win = vim.api.nvim_get_current_win()

    picker.open({
        prompt = "Switch Window",
        flags = FLAGS,
        enable_preview = true,
        finder = function(query, flags, _, callback)
            local items = {}
            for _, winid in ipairs(windows) do
                local config = vim.api.nvim_win_get_config(winid)
                local is_float = config.relative ~= ""
                if is_float and not flags.float then goto continue end

                local bufnr = vim.api.nvim_win_get_buf(winid)
                if not vim.bo[bufnr].buflisted and not flags.hidden then goto continue end

                local item = window_to_picker_item(winid, query, is_float, current_win)
                if item then table.insert(items, item) end
                ::continue::
            end
            callback(items)
        end,
        previewer = function(data, _, callback)
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
