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

---@type keystone.queryflags.FlagDef[]
local REF_FLAGS = {
    { name = "file", type = "value", multi = true, desc = "filter by filename" },
}

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
            flags = REF_FLAGS,
            enable_list_sep = true,
            enable_preview = true,
            preview_default = "visible",
            finder = function(query, flags, fetch_opts, callback)
                local picker_items = {}
                for _, ref in ipairs(lsp_items) do
                    local display_path = fsutils.get_relative_path(ref.filename) or ref.filename or ""
                    local filename = vim.fn.fnamemodify(display_path, ":t"):lower()
                    local skip = false
                    for _, v in ipairs(flags.file or {}) do
                        if not filename:find(v:lower(), 1, true) then
                            skip = true; break
                        end
                    end
                    if skip then goto continue end

                    local text = ref.text and vim.fn.trim(ref.text) or ""
                    local match = pickertools.match_label(text, query)
                    if match then
                        local loc = ref.lnum and string.format("%s:%d", display_path, ref.lnum) or display_path
                        loc = fsutils.smart_crop_path(loc, fetch_opts.list_width)
                        ---@type keystone.Picker.Item
                        table.insert(picker_items, {
                            label_chunks = match.chunks,
                            virt_lines = { { { loc, "Special" } } },
                            score = match.score,
                            data = {
                                filepath = ref.filename,
                                lnum = ref.lnum,
                                col = ref.col - 1,
                            }
                        })
                    end
                    ::continue::
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

---@type keystone.queryflags.FlagDef[]
local SYMBOL_FLAGS = {
    { name = "kind", type = "value", multi = true, desc = "filter by symbol kind: Function, Method, Class, ..." },
}

---@param opts {kinds:string[]?,prompt:string?}?
function M.document_symbols(opts)
    opts = opts or {}
    local params = { textDocument = vim.lsp.util.make_text_document_params() }
    local filepath = vim.api.nvim_buf_get_name(0)

    local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]

    vim.lsp.buf_request(0, "textDocument/documentSymbol", params, function(err, result, _)
        if err or not result then return end

        local items = {}
        local function flatten(symbols)
            for _, s in ipairs(symbols) do
                table.insert(items, {
                    kind = kind_to_string(s.kind),
                    data = {
                        name     = s.name,
                        filepath = filepath,
                        lnum     = s.selectionRange.start.line + 1,
                        col      = s.selectionRange.start.character,
                    }
                })
                if s.children then flatten(s.children) end
            end
        end
        flatten(result)

        local best, best_lnum = nil, 0
        for _, item in ipairs(items) do
            local lnum = item.data.lnum
            if lnum <= cursor_lnum and lnum > best_lnum then
                best      = item
                best_lnum = lnum
            end
        end
        if best then best.initial = true end

        if #items == 0 then
            vim.notify("No symbols found")
            return
        end

        -- opts.kinds seeds the flag default; inline --kind= flags extend it
        local opts_kind_filter = {}
        for _, k in ipairs(opts.kinds or {}) do opts_kind_filter[k:lower()] = true end

        picker.open({
            prompt = opts.prompt or "Document Symbols",
            flags = SYMBOL_FLAGS,
            enable_preview = true,
            preview_default = "visible",
            finder = function(query, flags, _, callback)
                local flag_kinds = flags.kind or {}
                local filtered = {}
                for _, item in ipairs(items) do
                    local kind_lower = item.kind:lower()
                    if next(opts_kind_filter) ~= nil then
                        if not opts_kind_filter[kind_lower] then goto continue end
                    end
                    local skip = false
                    for _, v in ipairs(flag_kinds) do
                        if not kind_lower:find(v:lower(), 1, true) then
                            skip = true; break
                        end
                    end
                    if skip then goto continue end

                    local match = pickertools.match_label(item.data.name, query)
                    if match then
                        vim.list_extend(match.chunks, {{ (' (%s)'):format(item.kind), "Comment" } })
                        table.insert(filtered, {
                            label_chunks = match.chunks,
                            score        = match.score,
                            data         = item.data,
                        })
                    end
                    ::continue::
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

return M
