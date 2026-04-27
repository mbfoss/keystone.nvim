local M = {}

local strutils = require("keystone.utils.strutils")
local fsutils = require("keystone.utils.fsutils")

---@param display_string string The final string to be shown
---@param positions integer[] Matched indices (already adjusted for any offsets)
---@param hl_group string? Optional override for the match highlight
---@return table[] chunks
function M.fuzzy_chunk_builder(display_string, positions, hl_group)
    if not positions or #positions == 0 then
        return { { display_string } }
    end

    local hl = hl_group or "Todo"
    local chunks = {}
    local pos_map = {}
    for _, p in ipairs(positions) do pos_map[p] = true end

    local current_chunk = ""
    local last_was_match = pos_map[1] or false

    for i = 1, #display_string do
        local is_match = pos_map[i] or false
        if is_match ~= last_was_match then
            table.insert(chunks, last_was_match and { current_chunk, hl } or { current_chunk })
            current_chunk = display_string:sub(i, i)
            last_was_match = is_match
        else
            current_chunk = current_chunk .. display_string:sub(i, i)
        end
    end

    if current_chunk ~= "" then
        table.insert(chunks, last_was_match and { current_chunk, hl } or { current_chunk })
    end
    return chunks
end

---@param match_target string What we match against
---@param query string User input
---@param opts { list_width: number, is_path: boolean }
---@return {score:number,chunks:string[][]}?
function M.make_picker_item(match_target, query, opts)
    local is_match, score, positions = strutils.fuzzy_match(match_target, query, {
        short_bias = not opts.is_path,
    })
    if not is_match and query ~= "" then return nil end

    local crop_offset = 0

    local final_display
    if opts.is_path then
        final_display = fsutils.smart_crop_path(match_target, opts.list_width)
        crop_offset = #final_display - #match_target
    elseif #match_target > opts.list_width then
        final_display = match_target:sub(1, opts.list_width - 3) .. "..."
    else
        final_display = match_target
    end
    local adjusted = {}
    if positions then
        for _, p in ipairs(positions) do
            local adj = p + crop_offset
            if adj >= 1 and adj <= #final_display then
                table.insert(adjusted, adj)
            end
        end
    end

    return {
        score = score or 0,
        chunks = M.fuzzy_chunk_builder(final_display, adjusted)
    }
end

---@param filepath string
---@param opts {lnum:number?, col:number?}
---@param callback fun(preview:string?,info:keystone.Picker.AsyncPreviewInfo?)
function M.default_file_preview(filepath, opts, callback)
    if not filepath or filepath == "" then
        vim.schedule(function()
            callback(nil, { error_msg = "No preview" })
        end)
        return function()
        end
    end
    if not fsutils.file_exists(filepath) then
        vim.schedule(function()
            callback(nil, { error_msg = "Invalid file path: " .. tostring(filepath) })
        end)
        return function()
        end
    end
    local cancel_fn = fsutils.async_load_text_file(filepath, { max_size = 50 * 1024 * 1024, timeout = 3000 },
        function(load_err, content)
            callback(content, {
                filepath = filepath,
                lnum = opts.lnum,
                col = opts.col,
                error_msg = load_err,
            })
        end)
    return cancel_fn
end

---@param name string
---@return keystone.Picker.QueryHistoryProvider
function M.make_history_provider(name)
    local file_path = vim.fs.joinpath(vim.fn.stdpath("data"), "keystonehist." .. name .. ".txt")
    local max_entries = 50
    ---@type keystone.Picker.QueryHistoryProvider
    local provider = {
        load = function()
            local hist = {}
            ---@type boolean,string
            local ok, lines = fsutils.read_content(file_path)
            if ok then
                hist = vim.split(lines, '\n')
            end
            return hist
        end,
        ---@param hist string[]
        store = function(hist)
            local start_idx = math.max(#hist - max_entries + 1, 1)
            local final_hist = {}
            for i = start_idx, #hist do
                table.insert(final_hist, hist[i])
            end
            fsutils.write_content(file_path, table.concat(final_hist, '\n'))
        end
    }

    return provider
end

return M
