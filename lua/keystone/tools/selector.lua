local picker    = require("keystone.tools.picker")
local filetools = require("keystone.tools.file")
local strtools  = require("keystone.tools.strtools")

local M         = {}

---@mod keystone.selector
---@brief Simple floating selector with fuzzy filtering and optional preview.

---@class keystone.SelectorItem
---@field label        string?             main displayed text (optional if label_chunks used)
---@field label_chunks {[1]:string, [2]:string?}[]?  optional, allows chunked labels with highlights
---@field file         string?
---@field lnum         number?
---@field virt_lines? {[1]:string, [2]:string?}[][] chunks: { { "text", "HighlightGroup?" }, ... }
---@field data         any                payload returned on select

---@alias keystone.SelectorCallback fun(data:any|nil)

---@alias keystone.PreviewFormatter fun(data:any):(string, string|nil)
--- Returns preview text and optional filetype

---@class keystone.selector.opts
---@field prompt string
---@field items keystone.SelectorItem?
---@field file_preview boolean?
---@field formatter keystone.PreviewFormatter|nil
---@field initial integer? -- 1-based index into items
---@field list_wrap boolean?

--------------------------------------------------------------------------------
-- Implementation Details
--------------------------------------------------------------------------------

local function _no_op()
end

---@param items keystone.SelectorItem[]
---@return number,number
local function _compute_dimentions(items)
    local maxw, height = 0, 0
    for _, item in ipairs(items) do
        if item.label then
            maxw = math.max(maxw, vim.fn.strdisplaywidth(item.label))
            height = height + 1
        end
        if item.label_chunks then
            height = height + 1
            local w = 0
            for _, chunk in ipairs(item.label_chunks) do
                w = w + vim.fn.strdisplaywidth(chunk[1])
            end
            maxw = math.max(maxw, w)
        end
        if item.virt_lines then
            for _, vl in ipairs(item.virt_lines) do
                height = height + 1
                local w = 0
                for _, chunk in ipairs(vl) do
                    w = w + vim.fn.strdisplaywidth(chunk[1])
                end
                maxw = math.max(maxw, w)
            end
        end
    end
    return maxw, height
end
---@param opts keystone.selector.opts
---@return keystone.Picker.Fetcher
local function _create_fetcher(opts)
    local items = opts.items or {}
    local initial_index = opts.initial or 1

    return function(query)
        local filtered = {}
        local q = query:lower()
        for _, item in ipairs(items) do
            local label = item.label or ""
            if not item.label and item.label_chunks then
                local parts = {}
                for _, chunk in ipairs(item.label_chunks) do
                    if chunk[1] then parts[#parts + 1] = chunk[1] end
                end
                label = table.concat(parts)
            end
            -- fuzzy match returns success, score, positions
            local ok, _, positions = strtools.fuzzy_match(label, q)
            if ok then
                -- build label_chunks for highlighting
                local chunks = item.label_chunks
                if item.label then
                    chunks = {}
                    local last = 0
                    for _, pos in ipairs(positions) do
                        if pos > last + 1 then
                            table.insert(chunks, { label:sub(last + 1, pos - 1) }) -- normal text
                        end
                        table.insert(chunks, { label:sub(pos, pos), "Label" })     -- highlight
                        last = pos
                    end
                    if last < #label then
                        table.insert(chunks, { label:sub(last + 1) })
                    end
                end
                table.insert(filtered, {
                    label_chunks = chunks,
                    virt_lines = item.virt_lines,
                    data = item
                })
            end
        end

        -- return filtered items + initial selection index
        return filtered, initial_index
    end
end

---@param opts keystone.selector.opts
---@return keystone.Picker.AsyncPreviewLoader|nil
local function _create_previewer(opts)
    -- If preview is disabled entirely, return nil
    if not opts.file_preview and not opts.formatter then
        return nil
    end

    return function(data, _, callback)
        -- 1. Use Formatter if provided
        if opts.formatter then
            local content, ft = opts.formatter(data.data)
            callback(content, { filetype = ft })
            return _no_op
        end
        -- 2. Fallback to Async File Loader if filepath exists
        if data.filepath or data.file then
            local path = data.filepath or data.file
            local cancel_fn = filetools.async_load_text_file(
                path,
                nil,
                function(_, content)
                    callback(content, {
                        filepath = path,
                        lnum = data.lnum,
                        col = data.col
                    })
                end
            )
            return cancel_fn
        end
        -- 3. No preview available for this item
        callback(nil)
        return _no_op
    end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

---@param opts keystone.selector.opts
---@param callback keystone.SelectorCallback
function M.select(opts, callback)
    local list_width, list_height = _compute_dimentions(opts.items)
    local height_ratio
    if not opts.formatter and not opts.file_preview then
       height_ratio = (list_height + 3) / vim.o.lines
    end
    -- Validate and prepare options for the underlying picker
    ---@type keystone.Picker.opts
    local picker_opts = {
        prompt        = opts.prompt,
        fetch         = _create_fetcher(opts),
        async_preview = _create_previewer(opts),
        list_width    = list_width,
        list_wrap     = opts.list_wrap,
        height_ratio  = height_ratio
    }

    picker.select(picker_opts, function(item)
        callback(item and item.data)
    end)

    -- Note: 'initial' index support would require modifying keystone.picker
    -- to accept an initial query or selection state.
end

return M
