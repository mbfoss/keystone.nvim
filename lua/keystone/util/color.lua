local M = {}

---@type table<string, {src:string, pct:integer}>  -- synced group -> source
local _synced = {}
local _augroup ---@type integer?

---Mix two 24-bit colours: `pct` percent of the way from `fg` to `bg`.
---@param fg integer
---@param bg integer
---@param pct integer
---@return integer
function M.mix(fg, bg, pct)
    local out = 0
    for _, scale in ipairs({ 65536, 256, 1 }) do
        local f, b = math.floor(fg / scale) % 256, math.floor(bg / scale) % 256
        out = out + math.floor(f + (b - f) * pct / 100 + 0.5) * scale
    end
    return out
end

---The background colours fade into: the one of `Normal`, or black/white when it has none.
---@return integer
function M.backdrop()
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    return normal.bg or (vim.o.background == "light" and 0xffffff or 0x000000)
end

---Define `dst` as the foreground of `src` faded `pct` percent into the background.
---Only the foreground is taken, so no block is painted behind the text. `ctermfg`
---comes over unfaded. `dst` links to `src` when `src` has no foreground.
---@param src string
---@param dst string
---@param pct integer
function M.blend(src, dst, pct)
    local hl = vim.api.nvim_get_hl(0, { name = src, link = false })
    if not (hl.fg or hl.ctermfg) then
        vim.api.nvim_set_hl(0, dst, { link = src })
        return
    end
    vim.api.nvim_set_hl(0, dst, {
        fg = hl.fg and M.mix(hl.fg, M.backdrop(), math.min(pct, 100)) or nil,
        ctermfg = hl.ctermfg,
    })
end

---@class keystone.util.color.CreateBlendedHlOpts
---@field src string  -- source group
---@field dst string  -- group to define
---@field pct integer  -- percent faded into the background, 0-100

---Define `opts.dst` as `opts.src` faded `opts.pct` percent into the background,
---and keep it in sync on every colorscheme change.
---@param opts keystone.util.color.CreateBlendedHlOpts
function M.create_blended_hl(opts)
    _synced[opts.dst] = { src = opts.src, pct = opts.pct }
    M.blend(opts.src, opts.dst, opts.pct)
    if not _augroup then
        _augroup = vim.api.nvim_create_augroup("KeystoneBlendedHl", { clear = true })
        vim.api.nvim_create_autocmd("ColorScheme", {
            group = _augroup,
            callback = function()
                for name, f in pairs(_synced) do M.blend(f.src, name, f.pct) end
            end,
        })
    end
end

return M
