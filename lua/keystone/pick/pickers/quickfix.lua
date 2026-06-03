local M = {}

local pickertools = require("keystone.pick.base.pickertools")
local uitool      = require("keystone.util.uitool")
local fsutil      = require("keystone.util.fsutil")

---@type keystone.queryflags.FlagDef[]
local FLAGS = {
    { name = "type", type = "value", multi = true, desc = "filter by type: E, W, I, N" },
    { name = "file", type = "value", multi = true, desc = "filter by filename"          },
}

---@alias keystone.pick.quickfix_filter 'all'|"errors"|"warnings"|"info"

local _type_prefix = {
    E = { "󰅚 ", "DiagnosticError" },
    W = { "󰀪 ", "DiagnosticWarn"  },
    I = { "󰋽 ", "DiagnosticInfo"  },
    N = { "󰌶 ", "DiagnosticHint"  },
}

---@param qf any
---@param filter keystone.pick.quickfix_filter
---@return boolean
local function matches_filter(qf, filter)
    if filter == "all" or not filter then return true end
    local t = (qf.type or ""):upper()
    if filter == "errors"   then return t == "E" or t == "" end
    if filter == "warnings" then return t == "W" end
    if filter == "info"     then return t == "I" end
    return true
end

---@param item table
---@return {filepath:string,relpath:string,lnum:number,col:number,bufnr:number,type:string,text:string}?
local function read_qf_item(item)
    local bufnr = item.bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    local relpath  = fsutil.get_relative_path(filepath) or filepath
    return {
        bufnr    = bufnr,
        filepath = filepath,
        relpath  = relpath,
        lnum     = item.lnum,
        col      = item.col > 0 and item.col - 1 or 0,
        type     = (item.type or ""):upper(),
        text     = item.text or "",
    }
end

---@param opts {filter:keystone.pick.quickfix_filter?}?
---@return keystone.PickerSpec?
function M.spec(opts)
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
        return nil
    end

    return {
        prompt          = "Quickfix Items",
        flags           = FLAGS,
        enable_list_sep = true,
        enable_preview  = true,
        finder          = function(query, flags, _, callback)
            local items = {}
            for _, data in ipairs(entries) do
                local skip       = false
                local type_flags = flags.type or {}
                if #type_flags > 0 then
                    local matched = false
                    for _, v in ipairs(type_flags) do
                        if data.type == v:upper() then matched = true; break end
                    end
                    if not matched then skip = true end
                end
                if not skip then
                    local filename = vim.fn.fnamemodify(data.relpath, ":t"):lower()
                    for _, v in ipairs(flags.file or {}) do
                        if not filename:find(v:lower(), 1, true) then skip = true; break end
                    end
                end
                if skip then goto continue end

                local text  = vim.trim(data.text ~= "" and data.text or "[No description]")
                local match = pickertools.match_label(text, query)
                if match then
                    local chunks     = { _type_prefix[data.type] or _type_prefix.N }
                    vim.list_extend(chunks, match.chunks)
                    local virt_lines = nil
                    if data.relpath and #data.relpath > 0 then
                        virt_lines = { { { string.format("%s:%d:%d", data.relpath, data.lnum, data.col), "Special" } } }
                    end
                    ---@type keystone.Picker.Item
                    table.insert(items, {
                        label_chunks = chunks,
                        score        = match.score,
                        virt_lines   = virt_lines,
                        data         = data,
                    })
                end
                ::continue::
            end
            table.sort(items, function(a, b) return a.score > b.score end)
            callback(items)
        end,
        quickfix_formatter = function(data)
            return data
        end,
        on_confirm = function(data)
            if data then uitool.smart_open_file(data.filepath, data.lnum, data.col) end
        end,
    }
end

return M
