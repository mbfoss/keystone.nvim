--- Builtin clue providers: dynamic generators (marks / registers) and static
--- description presets for common builtin prefixes (g / z / window).
local M = {}

---@param s string
---@param width integer
---@return string
local function _truncate(s, width)
    s = s:gsub("[\n\r]", "\\n"):gsub("\t", " ")
    if vim.fn.strchars(s) > width then
        s = vim.fn.strcharpart(s, 0, width) .. "…"
    end
    return s
end

--- Generate a clue item per mark (buffer-local marks first, then global).
---@return keystone.clue.Item[]
function M.marks()
    local items = {} ---@type keystone.clue.Item[]
    local seen = {} ---@type table<string, boolean>

    ---@param m table
    ---@param desc string
    local function add(m, desc)
        local name = m.mark:sub(2) -- drop the leading quote
        if name == "" or seen[name] then
            return
        end
        seen[name] = true
        items[#items + 1] = { key = name, desc = desc }
    end

    local buf = vim.api.nvim_get_current_buf()
    for _, m in ipairs(vim.fn.getmarklist(buf)) do
        local lnum = m.pos[2]
        local line = (vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""):gsub("^%s+", "")
        add(m, _truncate(("%d: %s"):format(lnum, line), 40))
    end
    for _, m in ipairs(vim.fn.getmarklist()) do
        add(m, _truncate(vim.fn.fnamemodify(m.file or "", ":~:."), 40))
    end
    return items
end

--- Registers worth offering with their (truncated) contents.
local _REGISTERS = [[abcdefghijklmnopqrstuvwxyz0123456789"-*+:.%/#=]]

---@return keystone.clue.Item[]
function M.registers()
    local items = {} ---@type keystone.clue.Item[]
    for i = 1, #_REGISTERS do
        local name = _REGISTERS:sub(i, i)
        local ok, content = pcall(vim.fn.getreg, name)
        if ok and type(content) == "string" and content ~= "" then
            items[#items + 1] = { key = name, desc = _truncate(content, 40) }
        end
    end
    return items
end

--- Builtin generators paired with the (mode, raw lhs) they attach to.
---@param enabled { marks?: boolean, registers?: boolean }
---@return { mode: string, keys: string, expand: fun(): keystone.clue.Item[] }[]
function M.generators(enabled)
    local out = {}
    if enabled.marks then
        for _, spec in ipairs({ { "n", "'" }, { "n", "`" }, { "x", "'" }, { "x", "`" } }) do
            out[#out + 1] = { mode = spec[1], keys = spec[2], expand = M.marks }
        end
    end
    if enabled.registers then
        for _, spec in ipairs({ { "n", '"' }, { "x", '"' }, { "i", "<C-r>" }, { "c", "<C-r>" } }) do
            out[#out + 1] = { mode = spec[1], keys = spec[2], expand = M.registers }
        end
    end
    return out
end

--- Static description presets for builtin keys. Each entry is a clue spec in the
--- same shape `keystone.clue.add` accepts.
---@return table[]
function M.preset_clues()
    local g = {
        { "gg", desc = "First line" },
        { "gd", desc = "Goto definition" },
        { "gD", desc = "Goto declaration" },
        { "gi", desc = "Goto implementation" },
        { "gr", desc = "References" },
        { "gx", desc = "Open under cursor" },
        { "g;", desc = "Older change" },
        { "g,", desc = "Newer change" },
        { "g&", desc = "Repeat last :s" },
        { "gv", desc = "Reselect" },
        { "gu", desc = "Lowercase", mode = { "n", "v" } },
        { "gU", desc = "Uppercase", mode = { "n", "v" } },
        { "g~", desc = "Toggle case", mode = { "n", "v" } },
    }
    local z = {
        { "zz", desc = "Center line" },
        { "zt", desc = "Line to top" },
        { "zb", desc = "Line to bottom" },
        { "zf", desc = "Create fold" },
        { "zo", desc = "Open fold" },
        { "zc", desc = "Close fold" },
        { "za", desc = "Toggle fold" },
        { "zR", desc = "Open all folds" },
        { "zM", desc = "Close all folds" },
    }
    local w = {
        { "<C-w>s", desc = "Split" },
        { "<C-w>v", desc = "Vsplit" },
        { "<C-w>c", desc = "Close" },
        { "<C-w>o", desc = "Only" },
        { "<C-w>w", desc = "Next window" },
        { "<C-w>h", desc = "Go left" },
        { "<C-w>j", desc = "Go down" },
        { "<C-w>k", desc = "Go up" },
        { "<C-w>l", desc = "Go right" },
        { "<C-w>=", desc = "Equalize" },
    }

    local clues = {}
    for _, list in ipairs({ g, z, w }) do
        vim.list_extend(clues, list)
    end
    return clues
end

return M
