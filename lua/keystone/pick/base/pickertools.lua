local M = {}

local strutils = require("keystone.utils.strutils")
local fsutils = require("keystone.utils.fsutils")

---@param text string The final string to be shown
---@param positions integer[] Matched indices
---@param hl_group string? Optional override for the match highlight
---@return table[] chunks
local function build_highlight_chunks(text, positions, hl_group)
    if not positions or #positions == 0 then
        return { { text } }
    end

    local hl = hl_group or "Todo"
    local chunks = {}
    local pos_map = {}
    for _, p in ipairs(positions) do pos_map[p] = true end

    local current_chunk = ""
    local last_was_match = pos_map[1] or false

    for i = 1, #text do
        local is_match = pos_map[i] or false
        if is_match ~= last_was_match then
            table.insert(chunks, last_was_match and { current_chunk, hl } or { current_chunk })
            current_chunk = text:sub(i, i)
            last_was_match = is_match
        else
            current_chunk = current_chunk .. text:sub(i, i)
        end
    end

    if current_chunk ~= "" then
        table.insert(chunks, last_was_match and { current_chunk, hl } or { current_chunk })
    end
    return chunks
end

---@param match_target string What we match against
---@param query string User input
---@param opts { maxlen: number?, is_path: boolean? }?
---@return {score:number,chunks:string[][]}?
function M.match_label(match_target, query, opts)
    opts = opts or {}
    local is_match, score, positions
    if opts.is_path then
        is_match, score, positions = strutils.fuzzy_match_path(match_target, query)
    else
        is_match, score, positions = strutils.fuzzy_match(match_target, query)
    end
    if not is_match and query ~= "" then return nil end
    local crop_offset = 0
    local final_display
    if opts.maxlen then
        local max_len = math.max(opts.maxlen or 3, 3)
        if opts.is_path then
            final_display = fsutils.smart_crop_path(match_target, max_len)
            crop_offset = #final_display - #match_target
        elseif #match_target > opts.maxlen then
            final_display = match_target:sub(1, max_len - 3) .. "..."
        else
            final_display = match_target
        end
    else
        final_display = match_target
    end
    local adjusted = {}
    if crop_offset ~= 0 then
        if positions then
            for _, p in ipairs(positions) do
                local adj = p + crop_offset
                if adj >= 1 and adj <= #final_display then
                    table.insert(adjusted, adj)
                end
            end
        end
    else
        adjusted = positions
    end
    return {
        score = score or 0,
        chunks = build_highlight_chunks(final_display, adjusted)
    }
end

---@param name string
---@param opts {max_entries:number?}?
---@return keystone.Picker.QueryHistoryProvider
function M.make_history_provider(name, opts)
    opts = opts or {}

    assert(type(name) == "string" and name:match("^[%w_]+$"), "invalid name")
    assert(not opts.max_entries or type(opts.max_entries) == "number")

    local file_path = vim.fs.joinpath(vim.fn.stdpath("data"), "keystonehist." .. name .. ".txt")
    local max_entries = opts.max_entries or 50
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
