local M = {}

local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local uitools = require("keystone.utils.uitools")

---@param severity vim.diagnostic.Severity LSP DiagnosticSeverity
---@return string, string (Text, HighlightGroup)
local function get_severity_info(severity)
    local map = {
        [vim.diagnostic.severity.ERROR] = { "󰅚", "DiagnosticError" },
        [vim.diagnostic.severity.WARN]  = { "󰀪", "DiagnosticWarn" },
        [vim.diagnostic.severity.INFO]  = { "󰋽", "DiagnosticInfo" },
        [vim.diagnostic.severity.HINT]  = { "󰌶", "DiagnosticHint" },
    }
    local res = map[severity] or { "󰠠", "Comment" }
    return res[1], res[2]
end

local function severity_to_qf_type(severity)
    if severity == vim.diagnostic.severity.ERROR then
        return "E"
    elseif severity == vim.diagnostic.severity.WARN then
        return "W"
    elseif severity == vim.diagnostic.severity.INFO then
        return "I"
    elseif severity == vim.diagnostic.severity.HINT then
        return "N"
    end
    return ""
end

---@param opts {bufnr:number?}?
function M.open(opts)
    opts = opts or {}
    local diagnostics = vim.diagnostic.get(opts.bufnr)

    if vim.tbl_isempty(diagnostics) then
        vim.notify("No diagnostics found", vim.log.levels.INFO)
        return
    end

    local filepath = vim.api.nvim_buf_get_name(opts.bufnr or 0)

    table.sort(diagnostics, function(a, b) return a.lnum < b.lnum end)
    local entries = {}
    for _, d in ipairs(diagnostics) do
        local sev_text, sev_hl = get_severity_info(d.severity)

        table.insert(entries, {
            message = d.message:gsub("\n", " "),
            severity = d.severity,
            prefix_chunks = {
                { sev_text,                          sev_hl },
                { string.format(" %3d", d.lnum + 1), "Number" },
                { ": ",                              "Comment" }
            },
            bufnr = d.bufnr,
            lnum = d.lnum + 1,
            col = d.col,
        })
    end

    picker.open({
        prompt = opts.bufnr and "Document Diagnostics" or "Worskpace Diagnostics",
        enable_preview = true,
        fetch = function(query, fetch_opts)
            local items = {}
            for _, entry in ipairs(entries) do
                local res = pickertools.match_label(entry.message, query, {
                    list_width = fetch_opts.list_width,
                    is_path = false
                })

                if res then
                    local chunks = vim.deepcopy(entry.prefix_chunks)
                    vim.list_extend(chunks, res.chunks)
                    table.insert(items, {
                        label_chunks = chunks,
                        data = {
                            message = entry.message,
                            severity = entry.severity,
                            bufnr = entry.bufnr,
                            lnum = entry.lnum,
                            col = entry.col,
                        },
                        score = res.score,
                        bufnr = entry.bufnr,
                        filepath = filepath,
                        lnum = entry.lnum,
                        col = entry.col,
                    })
                end
            end
            return items
        end,
        quickfix_formatter = function(data)
            ---@type vim.quickfix.entry
            return {
                type     = severity_to_qf_type(data.severity),
                text     = data.message,
                filename = data.filepath,
                lnum     = data.lnum or 1,
                col      = data.col or 0,
            }
        end
    }, function(selected)
        if selected then
            uitools.smart_open_buffer(selected.bufnr, selected.lnum, selected.col)
        end
    end)
end

return M
