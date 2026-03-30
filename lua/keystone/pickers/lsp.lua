local M = {}

local uitools = require("keystone.utils.uitools")
local strtools = require("keystone.utils.strtools")
local picker = require('keystone.utils.picker')
local pickertools = require("keystone.utils.pickertools")

-- Create a cache for the inverted table
local _kind_to_str_cache = {}
---@param kind number LSP SymbolKind (integer)
---@return string
local function kind_to_string(kind)
    -- Lazy-load the cache if empty
    if vim.tbl_isempty(_kind_to_str_cache) then
        local symbol_kinds = vim.lsp.protocol.SymbolKind
        for name, id in pairs(symbol_kinds) do
            -- Only map numbers to avoid metadata fields like __index
            if type(id) == "number" then
                _kind_to_str_cache[id] = name
            end
        end
    end
    return _kind_to_str_cache[kind] or ""
end


---@param result table LSP Reference result
---@param list_width number
---@return keystone.SelectorItem
local function lsp_item_to_picker_item(result, list_width)
    local uri = result.uri or result.targetUri
    local range = result.range or result.targetSelectionRange
    local filepath = vim.uri_to_fname(uri)
    local lnum = range.start.line + 1
    local col = range.start.character

    -- Get the text of the line to show in the picker
    -- Note: This is synchronous for the current buffer, but we might
    -- need to read from disk for other files.
    local line_text = ""
    if vim.uri_from_bufnr(0) == uri then
        line_text = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
    else
        -- Fallback: read line from file (or leave empty if too slow)
        line_text = vim.fn.getbufline(vim.fn.bufnr(filepath), lnum)[1] or "[External File]"
    end

    line_text = vim.trim(line_text)
    local display_path = strtools.smart_crop_path(vim.fn.fnamemodify(filepath, ":."), list_width)

    return {
        label = line_text,
        virt_lines = { { { string.format("%s:%d", display_path, lnum), "Comment" } } },
        data = {
            filepath = filepath,
            lnum = lnum,
            col = col,
        }
    }
end

function M.references()
    local params = vim.lsp.util.make_position_params(0, 'utf-8')
    local cursor_lnum = params.position.line
    local current_buf_uri = vim.uri_from_bufnr(0)
    ---@diagnostic disable-next-line: inject-field
    params.context = { includeDeclaration = true }

    vim.lsp.buf_request(0, "textDocument/references", params, function(err, result, ctx, _)
        if err then
            vim.notify("LSP Error: " .. err.message, vim.log.levels.ERROR)
            return
        end

        if not result or vim.tbl_isempty(result) then
            vim.notify("No LSP rererences found")
            return
        end

        picker.select({
            prompt = "LSP References",
            file_preview = true,
            fetch = function(query, fetch_opts)
                local items = {}
                for _, ref in ipairs(result) do
                    local range = ref.range or ref.targetSelectionRange
                    local uri = ref.uri or ref.targetUri

                    if not (uri == current_buf_uri and range.start.line == cursor_lnum) then
                        -- Get original item data
                        local item = lsp_item_to_picker_item(ref, fetch_opts.list_width)

                        -- Match query against the label (line text)
                        local match = pickertools.make_picker_item(item.label, query, {
                            list_width = fetch_opts.list_width,
                            is_path = false
                        })

                        if match then
                            item.label_chunks = match.chunks
                            item.score = match.score
                            table.insert(items, item)
                        end
                    end
                end
                table.sort(items, function(a, b) return a.score > b.score end)
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
                uitools.smart_open_file(data.filepath, data.lnum, data.col)
            end
        end)
    end)
end

---@param kinds string[]?
function M.document_symbols(kinds)
    local params = { textDocument = vim.lsp.util.make_text_document_params() }
    local filepath = vim.api.nvim_buf_get_name(0)

    vim.lsp.buf_request(0, "textDocument/documentSymbol", params, function(err, result, _)
        if err or not result then return end

        local kind_filter
        if kinds then
            kind_filter = {}
            for _, k in ipairs(kinds) do kind_filter[k] = true end
        end

        local items = {}
        local function flatten(symbols)
            for _, s in ipairs(symbols) do
                local kind_str = kind_to_string(s.kind)
                if not kind_filter or kind_filter[kind_str] then
                    table.insert(items, {
                        data = {
                            name = s.name,
                            filepath = filepath,
                            lnum = s.selectionRange.start.line + 1,
                            col = s.selectionRange.start.character
                        }
                    })
                end
                if s.children then flatten(s.children) end
            end
        end
        flatten(result)

        if #items == 0 then
            vim.notify("No symbols found")
            return
        end

        picker.select({
            prompt = "Document Symbols",
            fetch = function(query, fetch_opts)
                local filtered = {}
                for _, item in ipairs(items) do
                    -- Match against the symbol name
                    local match = pickertools.make_picker_item(item.data.name, query, {
                        list_width = fetch_opts.list_width,
                        is_path = false
                    })
                    if match then
                        table.insert(filtered, {
                            label_chunks = match.chunks,
                            score = match.score,
                            data = item.data
                        })
                    end
                end
                table.sort(filtered, function(a, b) return a.score > b.score end)
                return filtered
            end,
            async_preview = function(data, _, callback)
                return pickertools.default_file_preview(data.filepath, {
                    lnum = data.lnum,
                    col = data.col
                }, callback)
            end,
        }, function(data)
            if data then
                vim.api.nvim_win_set_cursor(0, { data.lnum, data.col })
            end
        end)
    end)
end

function M.document_functions()
    M.document_symbols({ "Function", "Constructor", "Method" })
end

return M
