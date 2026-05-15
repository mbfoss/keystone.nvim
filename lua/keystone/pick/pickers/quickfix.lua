local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local uitools = require("keystone.utils.uitools")
local fsutils = require("keystone.utils.fsutils")

local M = {}

---@alias keystone.pick.quickfix_filter 'all'|"errors"|"warnings"|"info"

local _type_prefix = {
    E = { "󰅚 ", "DiagnosticError" },
    W = { "󰀪 ", "DiagnosticWarn" },
    I = { "󰋽 ", "DiagnosticInfo" },
    N = { "󰌶 ", "DiagnosticHint" },
}
---@param qf any
---@param filter keystone.pick.quickfix_filter
---@return boolean
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

---@param item table
---@return {filepath:string,relpath:string,lnum:number,col:number,bufnr:number,type:string,text:string}?
local function read_qf_item(item)
    local bufnr = item.bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    local relpath = fsutils.get_relative_path(filepath) or filepath
    return {
        bufnr = bufnr,
        filepath = filepath,
        relpath = relpath,
        lnum = item.lnum,
        col = item.col > 0 and item.col - 1 or 0,
        type = (item.type or ""):upper(),
        text = item.text or "",
    }
end

---@param opts {filter:keystone.pick.quickfix_filter?}?
function M.open(opts)
    opts = opts or {}
    local filter = opts.filter or "all"
    local qflist = vim.fn.getqflist()

    local entries = {}
    for _, qf in ipairs(qflist) do
        if matches_filter(qf, filter) then
            local data = read_qf_item(qf)
            if data then table.insert(entries, data) end
        end
    end

    if vim.tbl_isempty(entries) then
        if filter == "all" then
            vim.notify("Quickfix list is empty", vim.log.levels.WARN)
        else
            vim.notify(("No %s in quickfix list"):format(filter), vim.log.levels.WARN)
        end
        return
    end

    picker.open({
            prompt = "Quickfix Items",
            enable_list_sep = true,
            enable_preview = true,
            fetch = function(query, fetch_opts)
                local items = {}
                for _, data in ipairs(entries) do
                    local text = vim.trim(data.text ~= "" and data.text or "[No description]")
                    local match = pickertools.match_label(text, query)
                    if match then
                        local chunks = { _type_prefix[data.type] or _type_prefix.N }
                        vim.list_extend(chunks, match.chunks)
                        local virt_lines = nil
                        if data.relpath and #data.relpath > 0 then
                            virt_lines = { { { string.format("%s:%d:%d", data.relpath, data.lnum, data.col), "Special" } } }
                        end
                        ---@type keystone.Picker.Item
                        local item = {
                            label_chunks = chunks,
                            score = match.score,
                            virt_lines = virt_lines,
                            data = data
                        }
                        table.insert(items, item)
                    end
                end
                table.sort(items, function(a, b) return a.score > b.score end)
                return items
            end,
            quickfix_formatter = function(data)
                return data
            end
        },
        function(data)
            if data then
                uitools.smart_open_file(data.filepath, data.lnum, data.col)
            end
        end)
end

return M
