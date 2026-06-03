local M = {}

local fsutil = require("keystone.util.fsutil")

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
    local nchars = vim.fn.strchars(text)

    for i = 1, nchars do
        local char = vim.fn.strcharpart(text, i - 1, 1)
        local is_match = pos_map[i] or false
        if is_match ~= last_was_match then
            table.insert(chunks, last_was_match and { current_chunk, hl } or { current_chunk })
            current_chunk = char
            last_was_match = is_match
        else
            current_chunk = current_chunk .. char
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
    if query == "" then
        return { score = 0, chunks = build_highlight_chunks(text, {}) }
    end
    local result = vim.fn.matchfuzzypos({ text }, query)
    if #result[1] == 0 then return nil end
    local raw_positions = result[2][1]
    local positions = {}
    for _, p in ipairs(raw_positions) do
        positions[#positions + 1] = p + 1 -- matchfuzzypos is 0-based; build_highlight_chunks expects 1-based
    end
    return {
        score = result[3][1],
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

    local dir = vim.fs.joinpath(vim.fn.stdpath("data"), "keystone")
    local file_path = vim.fs.joinpath(dir, "pickhist." .. name .. ".txt")
    local max_entries = opts.max_entries or 50
    ---@type keystone.Picker.QueryHistoryProvider
    local provider = {
        load = function()
            local hist = {}
            ---@type boolean,string
            local ok, lines = fsutil.read_content(file_path)
            if ok then
                hist = vim.split(lines, '\n')
            end
            return hist
        end,
        ---@param hist string[]
        store = function(hist)
            vim.fn.mkdir(dir, 'p')
            local start_idx = math.max(#hist - max_entries + 1, 1)
            local final_hist = {}
            for i = start_idx, #hist do
                local s = hist[i]
                assert(not s:match('\n'), "picker history item cannot contain \n")
                table.insert(final_hist, s)
            end
            fsutil.write_content(file_path, table.concat(final_hist, '\n'))
        end
    }

    return provider
end

return M
