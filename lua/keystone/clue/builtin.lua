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
        { "g_", desc = "Last non-blank character" },
        -- LSP/common
        { "gd", desc = "Goto definition" },
        { "gD", desc = "Goto declaration" },
        { "gi", desc = "Goto implementation" },
        { "gr", desc = "References" },
        { "gx", desc = "Open under cursor" },
        -- changes
        { "g;", desc = "Older change" },
        { "g,", desc = "Newer change" },
        { "g&", desc = "Repeat last :s" },
        -- visual
        { "gv", desc = "Reselect" },
        -- case
        { "gu", desc = "Lowercase",                 mode = { "n", "v" } },
        { "gU", desc = "Uppercase",                 mode = { "n", "v" } },
        { "g~", desc = "Toggle case",               mode = { "n", "v" } },
        -- formatting
        { "gq", desc = "Format text",               mode = { "n", "v" } },
        { "gw", desc = "Format text (keep cursor)", mode = { "n", "v" } },
        -- information
        { "K",  desc = "Keyword help" },
    }
    local z = {
        -- scrolling
        { "zz",    desc = "Center line" },
        { "zt",    desc = "Line to top" },
        { "zb",    desc = "Line to bottom" },
        { "z.",    desc = "Center line (first non-blank)" },
        { "z<CR>", desc = "Line to top (first non-blank)" },
        { "z-",    desc = "Line to bottom (first non-blank)" },
        -- folds
        { "zf",    desc = "Create fold" },
        { "zF",    desc = "Create fold for lines" },
        { "zd",    desc = "Delete fold" },
        { "zD",    desc = "Delete folds recursively" },
        { "zo",    desc = "Open fold" },
        { "zO",    desc = "Open folds recursively" },
        { "zc",    desc = "Close fold" },
        { "zC",    desc = "Close folds recursively" },
        { "za",    desc = "Toggle fold" },
        { "zA",    desc = "Toggle folds recursively" },
        { "zv",    desc = "Open folds for cursor" },
        { "zx",    desc = "Update folds" },
        { "zX",    desc = "Reapply folds" },
        { "zm",    desc = "More folding" },
        { "zM",    desc = "Close all folds" },
        { "zr",    desc = "Less folding" },
        { "zR",    desc = "Open all folds" },
        -- spelling
        { "zg",    desc = "Mark word good" },
        { "zw",    desc = "Mark word wrong" },
        { "z=",    desc = "Spelling suggestions" },
    }
    local w = {
        -- splits
        { "<C-w>s", desc = "Split" },
        { "<C-w>v", desc = "Vsplit" },
        { "<C-w>n", desc = "New window" },
        { "<C-w>q", desc = "Quit window" },
        { "<C-w>c", desc = "Close" },
        { "<C-w>o", desc = "Only" },
        -- navigation
        { "<C-w>w", desc = "Next window" },
        { "<C-w>W", desc = "Previous window" },
        { "<C-w>h", desc = "Go left" },
        { "<C-w>j", desc = "Go down" },
        { "<C-w>k", desc = "Go up" },
        { "<C-w>l", desc = "Go right" },
        { "<C-w>t", desc = "Top-left window" },
        { "<C-w>b", desc = "Bottom-right window" },
        { "<C-w>p", desc = "Previous window" },
        -- resizing
        { "<C-w>=", desc = "Equalize" },
        { "<C-w>+", desc = "Increase height" },
        { "<C-w>-", desc = "Decrease height" },
        { "<C-w>>", desc = "Increase width" },
        { "<C-w><", desc = "Decrease width" },
        { "<C-w>_", desc = "Maximize height" },
        { "<C-w>|", desc = "Maximize width" },
        -- moving/swap
        { "<C-w>H", desc = "Move window left" },
        { "<C-w>J", desc = "Move window down" },
        { "<C-w>K", desc = "Move window up" },
        { "<C-w>L", desc = "Move window right" },
        -- tabs
        { "<C-w>T", desc = "Move to new tab" },
        -- rotation/exchange
        { "<C-w>r", desc = "Rotate windows" },
        { "<C-w>R", desc = "Rotate windows (reverse)" },
        { "<C-w>x", desc = "Exchange windows" },
    }

    local clues = {}
    for _, list in ipairs({ g, z, w }) do
        vim.list_extend(clues, list)
    end
    return clues
end

return M
