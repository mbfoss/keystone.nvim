local M = {}

local uitools = require("keystone.utils.uitools")
local strtools = require("keystone.utils.strtools")
local picker = require('keystone.utils.picker')
local pickertools = require("keystone.utils.pickertools")
local _kind_to_str_cache = {}
---@param kind number LSP SymbolKind (integer)
---@return string
local function kind_to_string(kind)
    if vim.tbl_isempty(_kind_to_str_cache) then
        local symbol_kinds = vim.lsp.protocol.SymbolKind
        for name, id in pairs(symbol_kinds) do
            if type(id) == "number" then
                _kind_to_str_cache[id] = name
            end
        end
    end
    return _kind_to_str_cache[kind] or ""
end


---@param ref table LSP Reference result
---@param list_width number
---@return keystone.SelectorItem
local function lsp_item_to_picker_item(ref, list_width)
    local filepath = ref.filename
    local lnum = ref.lnum
    local col = ref.col
    local line_text = ref.text
    ---@type string?
    local loc = (lnum and string.format("%s:%d", filepath, lnum) or filepath) or ""
    loc = strtools.smart_crop_path(loc, list_width)
    if loc == "" then loc = nil end
    return {
        label = vim.trim(line_text or ""),
        virt_lines = { { { loc, "MoreMsg" } } },
        data = {
            filepath = filepath,
            lnum = lnum,
            col = col,
        }
    }
end

function M.references()
    local params = vim.lsp.util.make_position_params(0, 'utf-8')
    ---@diagnostic disable-next-line: inject-field
    params.context = { includeDeclaration = true }

    local action = "textDocument/references"
    vim.lsp.buf_request_all(0, action, params, function(results_per_client)
        local lsp_items = {}
        local first_encoding
        local errors = {}

        for client_id, result_or_error in pairs(results_per_client) do
            local error, result = result_or_error.err, result_or_error.result
            if error then
                errors[client_id] = error
            else
                if result ~= nil then
                    local locations = {}

                    if not vim.islist(result) then
                        vim.list_extend(locations, { result })
                    else
                        vim.list_extend(locations, result)
                    end

                    local offset_encoding = vim.lsp.get_client_by_id(client_id).offset_encoding

                    if not vim.tbl_isempty(result) then
                        first_encoding = offset_encoding
                    end

                    vim.list_extend(lsp_items, vim.lsp.util.locations_to_items(locations, offset_encoding))
                end
            end
        end

        for _, error in pairs(errors) do
            vim.notify(action .. " : " .. error.message, vim.log.levels.ERROR)
        end

        if vim.tbl_isempty(lsp_items) then
            vim.notify("No LSP rererences found")
            return
        end

        picker.select({
            prompt = "LSP References",
            file_preview = true,
            fetch = function(query, fetch_opts)
                local picker_items = {}
                for _, ref in ipairs(lsp_items) do
                    ---@type keystone.SelectorItem
                    local item = lsp_item_to_picker_item(ref, fetch_opts.list_width)
                    local match = pickertools.make_picker_item(item.label, query, {
                        list_width = fetch_opts.list_width,
                        is_path = false
                    })
                    if match then
                        item.label_chunks = match.chunks
                        item.score = match.score
                        table.insert(picker_items, item)
                    end
                end
                return picker_items
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
