local M = {}

local uitools = require("loop.tools.uitools")
local strtools = require("loop.tools.strtools")
local picker = require('loop.tools.picker')
local pickertools = require("loop.tools.pickertools")

-- Create a cache for the inverted table
local _kind_to_str_cache = {}
local _max_kind_str_len

---@param kind number LSP SymbolKind (integer)
---@return string, number
local function kind_to_string(kind)
    -- Lazy-load the cache if empty
    if vim.tbl_isempty(_kind_to_str_cache) then
        local symbol_kinds = vim.lsp.protocol.SymbolKind
        _max_kind_str_len = 0
        for name, id in pairs(symbol_kinds) do
            if type(id) == "number" then
                _max_kind_str_len = math.max(_max_kind_str_len, #name)
            end
        end
        for name, id in pairs(symbol_kinds) do
            -- Only map numbers to avoid metadata fields like __index
            if type(id) == "number" then
                _kind_to_str_cache[id] = name
            end
        end
    end
    return _kind_to_str_cache[kind] or "", _max_kind_str_len
end


---@param result table LSP Reference result
---@param list_width number
---@return loop.SelectorItem
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
    -- Capture current cursor position to compare later (0-indexed)
    local cursor_lnum = params.position.line
    local current_buf_uri = vim.uri_from_bufnr(0)
    ---@diagnostic disable-next-line: inject-field
    params.context = { includeDeclaration = true }

    -- Request references from LSP
    vim.lsp.buf_request(0, "textDocument/references", params, function(err, result, ctx, _)
        if err then
            vim.notify("LSP Error: " .. err.message, vim.log.levels.ERROR)
            return
        end

        if not result or vim.tbl_isempty(result) then
            vim.notify("No references found", vim.log.levels.INFO)
            return
        end

        -- Initialize the picker with the results
        picker.select({
            prompt = "LSP References",
            file_preview = true,
            -- Since the result is static, we don't use async_fetch (query-based)
            -- We pass the items directly via sync items or a simple fetcher
            fetch = function(query, fetch_opts)
                local items = {}
                for _, ref in ipairs(result) do
                    local range = ref.range or ref.targetSelectionRange
                    local uri = ref.uri or ref.targetUri

                    -- Check if this reference matches the cursor position exactly
                    local is_cursor_pos = uri == current_buf_uri and range.start.line == cursor_lnum
                    if not is_cursor_pos then
                        local item = lsp_item_to_picker_item(ref, fetch_opts.list_width)
                        if query == "" or item.label:lower():find(query:lower(), 1, true) then
                            table.insert(items, item)
                        end
                    end
                end
                return items
            end,
            async_preview = function(data, _, callback)
                return pickertools.default_file_preview(data.filepath, {
                    lnum = data.lnum,
                    col = data.col
                }, callback)
            end,
        }, function(selected)
            if selected then
                uitools.smart_open_file(selected.filepath, selected.lnum, selected.col)
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

        -- result is often a nested tree; you'll want to flatten it
        local items = {}
        local function flatten(symbols)
            for _, s in ipairs(symbols) do
                local kind_str, max_kind_len = kind_to_string(s.kind)
                local padded_kind_str = max_kind_len and strtools.pad_right(kind_str, max_kind_len) or kind_str
                if not kind_filter or kind_filter[kind_str] then
                    local item = { ---@type loop.Picker.Item
                        label_chunks = {
                            { padded_kind_str, "Special" },
                            { ": ",            "Comment" },
                            { s.name,          nil } },
                        data = {
                            name = s.name,
                            kind = s.kind, -- e.g., 12 for Function
                            filepath = filepath,
                            lnum = s.selectionRange.start.line + 1,
                            col = s.selectionRange.start.character
                        }
                    }
                    table.insert(items, item)
                end
                if s.children then flatten(s.children) end
            end
        end
        flatten(result)

        picker.select({
            prompt = "Document Symbols",
            fetch = function(query, fetch_opts)
                local list_width = fetch_opts.list_width
                -- Filter items based on query
                return vim.tbl_filter(function(i)
                    return i.data.name:lower():find(query:lower(), 1, true)
                end, items)
            end,
            async_preview = function(data, opts, callback)
                return pickertools.default_file_preview(data.filepath, {
                    lnum = data.lnum,
                    col = data.col
                }, callback)
            end,
            -- Use your existing previewer logic
        }, function(selected)
            if selected then
                vim.api.nvim_win_set_cursor(0, { selected.lnum, selected.col })
            end
        end)
    end)
end

function M.document_functions()
    M.document_symbols({ "Function", "Constructor", "Method" })
end

return M
