local M = {}

local uitools = require("keystone.utils.uitools")
local picker = require('keystone.utils.picker')
local pickertools = require("keystone.utils.pickertools")

---@param severity vim.diagnostic.Severity LSP DiagnosticSeverity
---@return string, string (Text, HighlightGroup)
local function get_severity_info(severity)
    local map = {
        [vim.diagnostic.severity.ERROR] = { "󰅚 ERROR", "DiagnosticError" },
        [vim.diagnostic.severity.WARN]  = { "󰀪 WARN ", "DiagnosticWarn" },
        [vim.diagnostic.severity.INFO]  = { "󰋽 INFO ", "DiagnosticInfo" },
        [vim.diagnostic.severity.HINT]  = { "󰌶 HINT ", "DiagnosticHint" },
    }
    local res = map[severity] or { "󰠠 ???? ", "Comment" }
    return res[1], res[2]
end

function M.document_diagnostics()
    local bufnr = vim.api.nvim_get_current_buf()
    local diagnostics = vim.diagnostic.get(bufnr)

    if vim.tbl_isempty(diagnostics) then
        vim.notify("No diagnostics found in current buffer", vim.log.levels.INFO)
        return
    end

    -- Sort by line number initially
    table.sort(diagnostics, function(a, b) return a.lnum < b.lnum end)

    -- Prepare the base data
    local raw_data = {}
    for _, d in ipairs(diagnostics) do
        local sev_text, sev_hl = get_severity_info(d.severity)

        table.insert(raw_data, {
            message = d.message:gsub("\n", " "),
            -- Fix: Define prefix_chunks here so it's available in fetch
            prefix_chunks = {
                { sev_text,                            sev_hl },
                { string.format(" %3d: ", d.lnum + 1), "Comment" }
            },
            data = {
                lnum = d.lnum + 1,
                col = d.col + 1,
                filepath = vim.api.nvim_buf_get_name(bufnr)
            }
        })
    end

    picker.select({
        prompt = "Document Diagnostics",
        file_preview = true,
        fetch = function(query, fetch_opts)
            local items = {}
            for _, item in ipairs(raw_data) do
                local res = pickertools.make_picker_item(item.message, query, item.message, {
                    list_width = fetch_opts.list_width,
                    is_path = false
                })

                if res then
                    -- Construct final chunk list
                    local final_chunks = vim.deepcopy(item.prefix_chunks)
                    vim.list_extend(final_chunks, res.chunks)

                    table.insert(items, {
                        label_chunks = final_chunks,
                        data = item.data,
                        score = res.score
                    })
                end
            end

            if query ~= "" then
                table.sort(items, function(a, b) return a.score > b.score end)
            end
            return items
        end,
        async_preview = function(data, _, callback)
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local content = table.concat(lines, "\n")
            vim.schedule(function()
                callback(content, {
                    filepath = data.filepath,
                    lnum = data.lnum,
                    col = data.col
                })
            end)
            return function() end
        end,
    }, function(selected)
        if selected then
            uitools.smart_open_file(selected.filepath, selected.lnum, selected.col)
        end
    end)
end

return M
