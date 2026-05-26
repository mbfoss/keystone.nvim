local M = {}

local uitools = require("keystone.utils.uitools")
local strutils = require("keystone.utils.strutils")
local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local fsutils = require("keystone.utils.fsutils")

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

function M.references()
    local params = vim.lsp.util.make_position_params(0, 'utf-8')
    ---@diagnostic disable-next-line: inject-field
    params.context = { includeDeclaration = true }

    local action = "textDocument/references"
    vim.lsp.buf_request_all(0, action, params, function(results_per_client)
        local lsp_items = {}
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

        picker.open({
            prompt = "LSP References",
            enable_list_sep = true,
            enable_preview = true,
            preview_default = "visible",
            finder = function(query, _, fetch_opts, callback)
                local picker_items = {}
                for _, ref in ipairs(lsp_items) do
                    local text = ref.text and vim.fn.trim(ref.text) or ""
                    local match = pickertools.match_label(text, query)
                    if match then
                        local display_path = fsutils.get_relative_path(ref.filename) or ref.filename or ""
                        local loc = ref.lnum and string.format("%s:%d", display_path, ref.lnum) or display_path
                        loc = fsutils.smart_crop_path(loc, fetch_opts.list_width)
                        ---@type keystone.Picker.Item
                        local item = {
                            label_chunks = match.chunks,
                            virt_lines = { { { loc, "Special" } } },
                            score = match.score,
                            data = {
                                filepath = ref.filename,
                                lnum = ref.lnum,
                                col = ref.col - 1,
                            }
                        }
                        table.insert(picker_items, item)
                    end
                end
                callback(picker_items)
            end,
        }, function(data)
            if data then
                uitools.smart_open_file(data.filepath, data.lnum, data.col)
            end
        end)
    end)
end

---@param opts {kinds:string[]?,prompt:string?}?
function M.document_symbols(opts)
    opts = opts or {}
    local params = { textDocument = vim.lsp.util.make_text_document_params() }
    local filepath = vim.api.nvim_buf_get_name(0)

    vim.lsp.buf_request(0, "textDocument/documentSymbol", params, function(err, result, _)
        if err or not result then return end

        local kind_filter
        if opts.kinds then
            kind_filter = {}
            for _, k in ipairs(opts.kinds) do kind_filter[k] = true end
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

        picker.open({
            prompt = opts.prompt or "Document Symbols",
            enable_preview = true,
            preview_default = "visible",
            finder = function(query, _, fetch_opts, callback)
                local filtered = {}
                for _, item in ipairs(items) do
                    local match = pickertools.match_label(item.data.name, query)
                    if match then
                        table.insert(filtered, {
                            label_chunks = match.chunks,
                            score = match.score,
                            data = item.data,
                        })
                    end
                end
                table.sort(filtered, function(a, b) return a.score > b.score end)
                callback(filtered)
            end,
        }, function(data)
            if data then
                vim.api.nvim_win_set_cursor(0, { data.lnum, data.col })
            end
        end)
    end)
end

function M.document_functions()
    M.document_symbols({ kinds = { "Function", "Constructor", "Method" }, prompt = "Document Functions" })
end

return M
