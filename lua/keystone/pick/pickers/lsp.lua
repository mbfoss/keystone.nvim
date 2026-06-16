local M                  = {}

local uitool             = require("keystone.util.uitool")
local strutil            = require("keystone.util.strutil")
local pickertools        = require("keystone.pick.base.pickertools")
local fsutil             = require("keystone.util.fsutil")

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

---@type keystone.queryflags.FlagDef[]
local SYMBOL_FLAGS = {
    {
        name = "kind",
        type = "value",
        multi = true,
        desc = "filter by symbol kind: Function, Method, Class, ...",
        values = {
            "File",
            "Module",
            "Namespace",
            "Package",
            "Class",
            "Method",
            "Property",
            "Field",
            "Constructor",
            "Enum",
            "Interface",
            "Function",
            "Variable",
            "Constant",
            "String",
            "Number",
            "Boolean",
            "Array",
            "Object",
            "Key",
            "Null",
            "EnumMember",
            "Struct",
            "Event",
            "Operator",
            "TypeParameter",
        }
    },
}

---@return keystone.PickerSpec
function M.references_spec()
    local params = vim.lsp.util.make_position_params(0, "utf-8")
    ---@diagnostic disable-next-line: inject-field
    params.context = { includeDeclaration = true }

    return {
        prompt          = "LSP References",
        flags           = REF_FLAGS,
        enable_list_sep = true,
        enable_preview  = true,
        preview_default = "visible",
        setup           = function(callback)
            local action = "textDocument/references"
            vim.lsp.buf_request_all(0, action, params, function(results_per_client)
                local lsp_items = {}
                local errors    = {}
                for client_id, result_or_error in pairs(results_per_client) do
                    local err, result = result_or_error.err, result_or_error.result
                    if err then
                        errors[client_id] = err
                    elseif result ~= nil then
                        local locations = vim.islist(result) and result or { result }
                        local enc       = vim.lsp.get_client_by_id(client_id).offset_encoding
                        vim.list_extend(lsp_items, vim.lsp.util.locations_to_items(locations, enc))
                    end
                end
                for _, err in pairs(errors) do
                    vim.notify(action .. " : " .. err.message, vim.log.levels.ERROR)
                end
                if vim.tbl_isempty(lsp_items) then
                    vim.notify("No LSP references found")
                    callback(nil)
                    return
                end
                callback({ lsp_items = lsp_items })
            end)
        end,
        finder          = function(query, flags, fetch_opts, callback, data)
            local picker_items = {}
            for _, ref in ipairs(data.lsp_items) do
                local display_path = fsutil.get_relative_path(ref.filename) or ref.filename or ""
                local filename     = vim.fn.fnamemodify(display_path, ":t"):lower()
                local skip         = false
                for _, v in ipairs(flags.file or {}) do
                    if not filename:find(v:lower(), 1, true) then
                        skip = true; break
                    end
                end
                if skip then goto continue end

                local text  = ref.text and vim.fn.trim(ref.text) or ""
                local match = pickertools.match_label(text, query)
                if match then
                    local loc = ref.lnum and string.format("%s:%d", display_path, ref.lnum) or display_path
                    loc = fsutil.smart_crop_path(loc, fetch_opts.list_width)
                    ---@type keystone.Picker.Item
                    table.insert(picker_items, {
                        label_chunks = match.chunks,
                        virt_lines   = { { { loc, "KeystonePickPath" } } },
                        score        = match.score,
                        data         = {
                            filepath = ref.filename,
                            lnum     = ref.lnum,
                            col      = ref.col - 1,
                        }
                    })
                end
                ::continue::
            end
            callback(picker_items)
        end,
        on_confirm      = function(data)
            if data then uitool.smart_open_file(data.filepath, data.lnum, data.col) end
        end,
    }
end

---@param opts {kinds:string[]?,prompt:string?}?
---@return keystone.PickerSpec
function M.document_symbols_spec(opts)
    opts                   = opts or {}

    local params           = { textDocument = vim.lsp.util.make_text_document_params() }
    local filepath         = vim.api.nvim_buf_get_name(0)
    local cursor_lnum      = vim.api.nvim_win_get_cursor(0)[1]

    local opts_kind_filter = {}
    for _, k in ipairs(opts.kinds or {}) do opts_kind_filter[k:lower()] = true end

    return {
        prompt          = opts.prompt or "Document Symbols",
        flags           = SYMBOL_FLAGS,
        enable_preview  = true,
        preview_default = "visible",
        setup           = function(callback)
            vim.lsp.buf_request(0, "textDocument/documentSymbol", params, function(err, result, _)
                if err or not result then
                    callback(nil)
                    return
                end

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
                            },
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
                    callback(nil)
                    return
                end
                callback({ items = items })
            end)
        end,
        finder          = function(query, flags, _, callback, data)
            local flag_kinds = flags.kind or {}
            local filtered   = {}
            for _, item in ipairs(data.items) do
                local kind_lower = item.kind:lower()
                if next(opts_kind_filter) ~= nil and not opts_kind_filter[kind_lower] then
                    goto continue
                end
                if #flag_kinds > 0 then
                    local matched = false
                    for _, v in ipairs(flag_kinds) do
                        for part in v:lower():gmatch("[^,]+") do
                            if kind_lower == part then
                                matched = true; break
                            end
                        end
                        if matched then break end
                    end
                    if not matched then goto continue end
                end

                local match = pickertools.match_label(item.data.name, query)
                if match then
                    vim.list_extend(match.chunks, { { (" (%s)"):format(item.kind), "Comment" } })
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
        on_confirm      = function(data)
            if data then vim.api.nvim_win_set_cursor(0, { data.lnum, data.col }) end
        end,
    }
end

return M
