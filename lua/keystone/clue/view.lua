--- The clue popup: a non-focusable floating window anchored to the bottom of
--- the editor, rendering the children of the current node in auto-sized columns.
local Tree = require("keystone.clue.tree")
local Keys = require("keystone.clue.keys")

local M = {}

local _dw = vim.fn.strdisplaywidth

M._buf = nil ---@type integer?
M._win = nil ---@type integer?
M._ns = vim.api.nvim_create_namespace("keystone_clue")

--- Max display width of a hint description; longer ones are cropped with `…`.
--- Set from `config.max_desc_width` by `clue.setup`. 0 disables cropping.
M.max_desc_width = 40 ---@type integer

local HL_KEY = "KeystoneClueKey"
local HL_SEP = "KeystoneClueSep"
local HL_DESC = "KeystoneClueDesc"
local HL_GROUP = "KeystoneClueGroup"

local SEP = " → "
local SEP_W = _dw(SEP)
local COL_GAP = "  "
local COL_GAP_W = 2

--- Register highlight groups as overridable `default` links and keep them in
--- sync across colorscheme changes.
function M.setup_hl()
    local function apply()
        vim.api.nvim_set_hl(0, HL_KEY, { default = true, link = "DiagnosticHint" })
        vim.api.nvim_set_hl(0, HL_SEP, { default = true, link = "Comment" })
        vim.api.nvim_set_hl(0, HL_DESC, { default = true, link = nil })
        vim.api.nvim_set_hl(0, HL_GROUP, { default = true, link = "Function" })
    end
    apply()
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("KeystoneClueHighlights", { clear = true }),
        callback = apply,
    })
end

---@type table<string, string>
local _key_alias = {
    [" "] = "␣",
    ["<Space>"] = "␣",
}

---@param token string
---@return string
local function _disp_key(token)
    return _key_alias[token] or token
end

--- Sanitise newlines/tabs and crop `s` to at most `max_w` display columns,
--- appending `…` when cropped. `max_w <= 0` only sanitises (no cropping).
---@param s string
---@param max_w integer
---@return string
local function _truncate(s, max_w)
    s = s:gsub("[\r\n\t]", " ")
    if max_w <= 0 or _dw(s) <= max_w then
        return s
    end
    local limit = math.max(0, max_w - 1) -- leave one column for the ellipsis
    local cut = vim.fn.strchars(s)
    while cut > 0 and _dw(vim.fn.strcharpart(s, 0, cut)) > limit do
        cut = cut - 1
    end
    return vim.fn.strcharpart(s, 0, cut) .. "…"
end

---@class keystone.clue.Entry
---@field key string
---@field desc string
---@field group boolean

---@param node keystone.clue.Node
---@return keystone.clue.Entry[], integer key_w, integer desc_w
local function _entries(node)
    local out = {} ---@type keystone.clue.Entry[]
    local key_w, desc_w = 0, 0
    for _, child in ipairs(Tree.children(node)) do
        local is_group = child.group or Tree.has_children(child)
        local desc = child.desc
        if not desc or desc == "" then
            if is_group then
                desc = "+" .. child.key
            elseif child.keymap and type(child.keymap.rhs) == "string" then
                desc = child.keymap.rhs
            else
                desc = ""
            end
        end
        if is_group and not desc:match("^%+") then
            desc = "+" .. desc
        end
        desc = _truncate(desc, M.max_desc_width)
        local key = _disp_key(child.key)
        out[#out + 1] = { key = key, desc = desc, group = is_group }
        key_w = math.max(key_w, _dw(key))
        desc_w = math.max(desc_w, _dw(desc))
    end
    return out, key_w, desc_w
end

--- Lay entries out in column-major order, returning rendered lines plus per-line
--- highlight ranges `{ start_col, end_col, hl_group }` (byte columns).
---@param entries keystone.clue.Entry[]
---@param key_w integer
---@param desc_w integer
---@return string[] lines, table[][] highlights
local function _render(entries, key_w, desc_w)
    local cell_w = key_w + SEP_W + desc_w
    local avail = vim.o.columns - 4
    local ncols = math.max(1, math.floor((avail + COL_GAP_W) / (cell_w + COL_GAP_W)))
    ncols = math.min(ncols, #entries)
    local nrows = math.ceil(#entries / ncols)

    local max_rows = math.max(1, math.floor(vim.o.lines * 0.4))
    if nrows > max_rows then
        nrows = max_rows
        ncols = math.ceil(#entries / nrows)
    end

    local lines = {} ---@type string[]
    local highlights = {} ---@type table[][]

    for r = 1, nrows do
        local parts = {} ---@type string[]
        local hls = {} ---@type table[]
        local col = 0
        for c = 1, ncols do
            local e = entries[(c - 1) * nrows + r]
            if e then
                local key = (" "):rep(key_w - _dw(e.key)) .. e.key
                local desc = e.desc .. (" "):rep(math.max(0, desc_w - _dw(e.desc)))

                local s = col
                parts[#parts + 1] = key
                col = col + #key
                hls[#hls + 1] = { s, col, HL_KEY }

                s = col
                parts[#parts + 1] = SEP
                col = col + #SEP
                hls[#hls + 1] = { s, col, HL_SEP }

                s = col
                parts[#parts + 1] = desc
                col = col + #desc
                hls[#hls + 1] = { s, col, e.group and HL_GROUP or HL_DESC }

                if c < ncols then
                    parts[#parts + 1] = COL_GAP
                    col = col + COL_GAP_W
                end
            end
        end
        lines[#lines + 1] = (table.concat(parts):gsub("%s+$", ""))
        highlights[#highlights + 1] = hls
    end
    return lines, highlights
end

--- Build centered footer chunks showing the pending key sequence (the keys
--- typed so far to reach `node`), e.g. `<leader>f` → `␣f`. Nil when there is no
--- prefix yet or the popup has no border to host a footer.
---@param node keystone.clue.Node
---@return table[]?
local function _footer(node)
    if not node.keys or node.keys == "" then
        return nil
    end
    if M.border == "none" or M.border == "" or M.border == "shadow" then
        return nil
    end
    local parts = {} ---@type string[]
    for _, tok in ipairs(Keys.split(node.keys)) do
        parts[#parts + 1] = _disp_key(tok)
    end
    local str = table.concat(parts)
    if str == "'" then
        str = "' (marks)"
    elseif str == '"' then
        str = '" (registers)'
    end
    return { { " " .. str .. " ", nil } }
end

---@param width integer
---@param height integer
---@param for_open boolean
---@param footer table[]?
---@return vim.api.keyset.win_config
local function _win_config(width, height, for_open, footer)
    local cfg = {
        relative = "editor",
        width = width,
        height = height,
        row = vim.o.lines - height - 2 - vim.o.cmdheight,
        col = math.floor((vim.o.columns - width) / 2),
        zindex = 250,
        border = M.border or "rounded",
        focusable = false,
        footer = footer,
        footer_pos = footer and "center" or nil,
    }
    if for_open then
        cfg.style = "minimal"
        cfg.noautocmd = true
    end
    return cfg
end

---@return boolean
function M.visible()
    return M._win ~= nil and vim.api.nvim_win_is_valid(M._win)
end

--- Build/refresh the popup for `node` and force a redraw so it appears even
--- while the engine is blocked in `getcharstr`.
---@param node keystone.clue.Node
function M.show(node)
    local entries, key_w, desc_w = _entries(node)
    if #entries == 0 then
        M.hide()
        return
    end
    local lines, highlights = _render(entries, key_w, desc_w)

    local width = 1
    for _, l in ipairs(lines) do
        width = math.max(width, _dw(l))
    end
    width = math.min(width, vim.o.columns - 2)
    local height = #lines

    if not M._buf or not vim.api.nvim_buf_is_valid(M._buf) then
        M._buf = vim.api.nvim_create_buf(false, true)
        vim.bo[M._buf].bufhidden = "wipe"
    end
    vim.bo[M._buf].modifiable = true
    vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, lines)
    vim.bo[M._buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(M._buf, M._ns, 0, -1)
    for r, hls in ipairs(highlights) do
        local len = #lines[r]
        for _, h in ipairs(hls) do
            if h[1] < len then
                vim.api.nvim_buf_set_extmark(M._buf, M._ns, r - 1, h[1], {
                    end_col = math.min(h[2], len),
                    hl_group = h[3],
                })
            end
        end
    end

    local footer = _footer(node)
    -- A footer can be wider than the content; widen so it is not clipped.
    if footer then
        local fw = _dw(footer[1][1])
        width = math.min(math.max(width, fw), vim.o.columns - 2)
    end

    if M.visible() then
        vim.api.nvim_win_set_config(M._win, _win_config(width, height, false, footer))
    else
        M._win = vim.api.nvim_open_win(M._buf, false, _win_config(width, height, true, footer))
        vim.wo[M._win].wrap = false
        vim.wo[M._win].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder"
    end

    vim.cmd("redraw")
end

function M.hide()
    if M.visible() then
        pcall(vim.api.nvim_win_close, M._win, true)
    end
    M._win = nil
end

return M
