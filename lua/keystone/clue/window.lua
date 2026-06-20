--- Floating window that renders `keystone.clue` entries in a multi-column grid
--- pinned to the bottom of the editor. The window is informational only — it is
--- never focused; key reading happens in the originating window.
local M = {}

M.KEY_HL   = "KeystoneClueKey"
M.DESC_HL  = "KeystoneClueDesc"
M.GROUP_HL = "KeystoneClueGroup"
M.SEP_HL   = "KeystoneClueSeparator"
M.TITLE_HL = "KeystoneClueTitle"

local _ns = vim.api.nvim_create_namespace("keystone_clue")

---@param name string
---@param opts vim.api.keyset.highlight
local function _def(name, opts)
    if next(vim.api.nvim_get_hl(0, { name = name })) == nil then
        vim.api.nvim_set_hl(0, name, opts)
    end
end

--- Register clue highlight groups (re-applied on `ColorScheme` since `default`
--- links are cleared when the colorscheme changes).
function M.setup_hl()
    local function apply()
        _def(M.KEY_HL, { default = true, link = "Special" })
        _def(M.DESC_HL, { default = true, link = nil })
        _def(M.GROUP_HL, { default = true, link = "Function" })
        _def(M.SEP_HL, { default = true, link = "Comment" })
        _def(M.TITLE_HL, { default = true, link = "FloatTitle" })
    end
    apply()
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("KeystoneClueHighlights", { clear = true }),
        callback = apply,
    })
end

---@param s string
---@param width integer max display width
---@return string
local function _truncate(s, width)
    if vim.fn.strdisplaywidth(s) <= width then
        return s
    end
    if width <= 1 then
        return "…"
    end
    local out, w, i = {}, 0, 0
    while true do
        local ch = vim.fn.strcharpart(s, i, 1)
        if ch == "" then
            break
        end
        local cw = vim.fn.strdisplaywidth(ch)
        if w + cw > width - 1 then
            break
        end
        out[#out + 1] = ch
        w = w + cw
        i = i + 1
    end
    return table.concat(out) .. "…"
end

---@return integer
local function _bottom_offset()
    return vim.o.cmdheight + (vim.o.laststatus ~= 0 and 1 or 0) + 2
end

--- Lay out entries column-major into padded rows, recording highlight spans.
---@param entries keystone.clue.Entry[]
---@param win_cfg table
---@return string[] lines
---@return table[] hls  per-row list of {col_start, col_end, hl_group}
---@return integer width
local function _build(entries, win_cfg)
    local sep = win_cfg.separator or "  "
    local sep_w = vim.fn.strdisplaywidth(sep)
    local gutter = 2

    local max_key, max_desc = 1, 1
    for _, e in ipairs(entries) do
        max_key = math.max(max_key, vim.fn.strdisplaywidth(e.key))
        max_desc = math.max(max_desc, vim.fn.strdisplaywidth(e.desc))
    end
    max_desc = math.min(max_desc, math.max(10, math.floor(vim.o.columns * 0.25)))

    local cell_w = max_key + sep_w + max_desc
    local total_w = math.min(
        math.floor(vim.o.columns * (win_cfg.width_ratio or 0.9)),
        vim.o.columns - 4
    )

    local cols = math.max(1, math.floor((total_w + gutter) / (cell_w + gutter)))
    cols = math.min(cols, #entries)

    local max_rows = math.max(1, math.floor(vim.o.lines * (win_cfg.max_height_ratio or 0.4)))
    local rows = math.ceil(#entries / cols)
    while rows > max_rows and cols < #entries do
        cols = cols + 1
        rows = math.ceil(#entries / cols)
    end
    rows = math.min(rows, max_rows)

    local row_text = {} ---@type string[]
    local row_hls = {} ---@type table[][]
    for r = 1, rows do
        row_text[r] = ""
        row_hls[r] = {}
    end

    for idx, e in ipairs(entries) do
        local col = math.floor((idx - 1) / rows)
        local row = (idx - 1) % rows + 1
        if col >= cols then
            break
        end

        local key_w = vim.fn.strdisplaywidth(e.key)
        local key_pad = string.rep(" ", math.max(0, max_key - key_w))
        local desc = _truncate(e.desc, max_desc)
        local desc_w = vim.fn.strdisplaywidth(desc)
        local desc_pad = string.rep(" ", math.max(0, max_desc - desc_w))
        local cell_prefix = (col > 0) and string.rep(" ", gutter) or ""

        local base = #row_text[row] + #cell_prefix
        local k0 = base + #key_pad
        local k1 = base + #key_pad + #e.key
        local s0 = k1
        local s1 = s0 + #sep
        local d0 = s1
        local d1 = d0 + #desc

        row_text[row] = row_text[row]
            .. cell_prefix .. key_pad .. e.key .. sep .. desc .. desc_pad

        table.insert(row_hls[row], { k0, k1, M.KEY_HL })
        table.insert(row_hls[row], { s0, s1, M.SEP_HL })
        table.insert(row_hls[row], { d0, d1, e.is_group and M.GROUP_HL or M.DESC_HL })
    end

    local lines, width = {}, 1
    for r = 1, rows do
        lines[r] = (row_text[r]:gsub("%s+$", ""))
        width = math.max(width, vim.fn.strdisplaywidth(lines[r]))
    end

    return lines, row_hls, width
end

---@param buf integer
---@param hls table[][]
local function _apply_hl(buf, hls)
    for r, list in ipairs(hls) do
        for _, h in ipairs(list) do
            vim.api.nvim_buf_set_extmark(buf, _ns, r - 1, h[1], {
                end_col = h[2],
                hl_group = h[3],
            })
        end
    end
end

---@param width integer
---@param height integer
---@param title string?
---@param win_cfg vim.api.keyset.win_config
---@return vim.api.keyset.win_config
local function _win_config(width, height, title, win_cfg)
    local cfg = { ---@type vim.api.keyset.win_config
        relative = "editor",
        width = width,
        height = height,
        row = math.max(0, vim.o.lines - height - _bottom_offset()),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        border = win_cfg.border or "rounded",
    }
    if win_cfg.title ~= false and title then
        cfg.footer = { { title, M.TITLE_HL } }
        cfg.footer_pos = "center"
    end
    return cfg
end

---@class keystone.clue.WinHandle
---@field win integer
---@field buf integer

--- Open the clue window.
---@param entries keystone.clue.Entry[]
---@param title string?
---@param win_cfg table
---@return keystone.clue.WinHandle
function M.open(entries, title, win_cfg)
    win_cfg = win_cfg or {}
    local lines, hls, width = _build(entries, win_cfg)
    local height = #lines

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    _apply_hl(buf, hls)
    vim.bo[buf].modifiable = false

    local cfg = _win_config(width, height, title, win_cfg)
    cfg.style = "minimal"
    cfg.focusable = false
    cfg.noautocmd = true
    cfg.zindex = 200

    local win = vim.api.nvim_open_win(buf, false, cfg)
    vim.wo[win].wrap = false
    vim.wo[win].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder,FloatTitle:FloatTitle"

    return { win = win, buf = buf }
end

--- Re-render an existing clue window with new entries / title.
---@param handle keystone.clue.WinHandle
---@param entries keystone.clue.Entry[]
---@param title string?
---@param win_cfg table
function M.update(handle, entries, title, win_cfg)
    if not (handle and vim.api.nvim_win_is_valid(handle.win)) then
        return
    end
    win_cfg = win_cfg or {}
    local lines, hls, width = _build(entries, win_cfg)
    local height = #lines

    vim.bo[handle.buf].modifiable = true
    vim.api.nvim_buf_clear_namespace(handle.buf, _ns, 0, -1)
    vim.api.nvim_buf_set_lines(handle.buf, 0, -1, false, lines)
    _apply_hl(handle.buf, hls)
    vim.bo[handle.buf].modifiable = false

    vim.api.nvim_win_set_config(handle.win, _win_config(width, height, title, win_cfg))
end

---@param handle keystone.clue.WinHandle?
function M.close(handle)
    if not handle then
        return
    end
    if handle.win and vim.api.nvim_win_is_valid(handle.win) then
        vim.api.nvim_win_close(handle.win, true)
    end
    if handle.buf and vim.api.nvim_buf_is_valid(handle.buf) then
        pcall(vim.api.nvim_buf_delete, handle.buf, { force = true })
    end
end

return M
