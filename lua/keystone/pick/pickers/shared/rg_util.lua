local M = {}

---@class keystone.rgutil.Submatch
---@field s    integer  -- 0-indexed byte start in the line
---@field e    integer  -- 0-indexed byte end (exclusive) in the line
---@field repl string?  -- rg-computed replacement text (nil unless --replace was used)

---@class keystone.rgutil.Match
---@field path string
---@field lnum integer
---@field col  integer  -- 1-indexed byte column of the first submatch
---@field text string
---@field subs keystone.rgutil.Submatch[]

---Parse a single line of `rg --json` output into a match descriptor.
---Lines that are not `type == "match"` (begin/end/summary) yield nil.
---@param line string
---@return keystone.rgutil.Match?
function M.parse_match(line)
    local ok, decoded = pcall(vim.json.decode, line)
    if not ok or not decoded or decoded.type ~= "match" then return end

    local data = decoded.data
    local path = data.path and data.path.text
    if not path then return end

    local text = data.lines.text or data.lines.bytes or ""
    text       = text:gsub("\r?\n$", "")

    local subs = {}
    for _, m in ipairs(data.submatches or {}) do
        subs[#subs + 1] = {
            s    = m.start,
            e    = m["end"],
            repl = m.replacement and m.replacement.text or nil,
        }
    end

    local col = (subs[1] and subs[1].s + 1) or 1
    return { path = path, lnum = data.line_number, col = col, text = text, subs = subs }
end

---Build label chunks from a line and its submatches.  When `use_repl` is set,
---matched spans are swapped for their rg replacement text (the "after" line);
---otherwise the matched text is highlighted verbatim (the "before" line).
---@param text     string
---@param subs     keystone.rgutil.Submatch[]
---@param match_hl string
---@param use_repl boolean?
---@return {[1]:string,[2]:string?}[]
function M.build_chunks(text, subs, match_hl, use_repl)
    local chunks = {}
    local last   = 1
    for _, sm in ipairs(subs) do
        local s = sm.s + 1
        local e = sm.e
        if s > last then
            chunks[#chunks + 1] = { text:sub(last, s - 1) }
        end
        if use_repl then
            if sm.repl and #sm.repl > 0 then
                chunks[#chunks + 1] = { sm.repl, match_hl }
            end
        else
            chunks[#chunks + 1] = { text:sub(s, e), match_hl }
        end
        last = e + 1
    end
    if last <= #text then
        chunks[#chunks + 1] = { text:sub(last) }
    end
    return chunks
end

return M
