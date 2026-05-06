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

---@param text string What we match against
---@param query string User input
---@return {score:number,chunks:string[][]}?
function M.match_label(text, query)
    local is_match, score, positions = strutils.fuzzy_match_path(text, query)
    if not is_match then return nil end
    return {
        score = score or 0,
        chunks = build_highlight_chunks(text, positions)
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
