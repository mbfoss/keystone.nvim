local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local uitools = require("keystone.utils.uitools")
local fsutils = require("keystone.utils.fsutils")

local M = {}

---@param item vim.fn.getjumplist.ret.item
---@return {filepath:string, relpath:string, lnum:number,col:number,bufnr:number}?
local function read_jump_item(item)
    local bufnr = item.bufnr
    if not bufnr or bufnr == 0 then return nil end
    if not vim.api.nvim_buf_is_valid(bufnr) then return nil end
    local filepath = item.filename or vim.api.nvim_buf_get_name(bufnr)
    local relpath = fsutils.get_relative_path(filepath) or filepath
    return {
        bufnr = bufnr,
        filepath = filepath,
        relpath = relpath,
        lnum = item.lnum,
        col = (item.col or 1) - 1,
    }
end

function M.open()
    local jumplist, _ = unpack(vim.fn.getjumplist())
    if not jumplist or vim.tbl_isempty(jumplist) then
        vim.notify("Jumplist is empty", vim.log.levels.WARN)
        return
    end

    ---@type {filepath:string, relpath:string, lnum:number,col:number,bufnr:number}[]
    local entries = {}
    for i = #jumplist, 1, -1 do
        local data = read_jump_item(jumplist[i])
        if data then table.insert(entries, data) end
    end

    picker.open({
        prompt = "Jumplist",
        enable_preview = true,
        finder = function(query, _, fetch_opts, callback)
            local items = {}
            for _, data in ipairs(entries) do
                local label = data.relpath or ""
                if label == "" then label = "[No Name]" end
                local match = pickertools.match_label(label, query)
                if match then
                    table.insert(match.chunks, { string.format(":%d:%d", data.lnum, data.col) })
                    ---@type keystone.Picker.Item
                    local item = {
                        label_chunks = match.chunks,
                        score = match.score,
                        data = {
                            filepath = data.filepath,
                            bufnr = data.bufnr,
                            lnum = data.lnum,
                            col = data.col,
                        }
                    }
                    table.insert(items, item)
                end
            end
            callback(items)
        end,
    }, function(data)
        if data then
            uitools.smart_open_buffer(data.bufnr, data.lnum, data.col)
        end
    end)
end

return M
