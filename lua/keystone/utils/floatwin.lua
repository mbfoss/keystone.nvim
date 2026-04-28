---@class keystone.utils.floatwin
---@field _complete_cache? string[]
---@field _complete_buf? integer
local M = {}

local debug_win_augroup = vim.api.nvim_create_augroup("keystone_modalwin", { clear = true })
local _current_win = nil


---@class keystone.floatwin.FloatwinOpts
---@field title? string
---@field is_hover? boolean
---@field move_to_bot? boolean
---@field is_markdown boolean?


---@param text string
function _open_hoverwindow(text)
    local lines              = vim.split(text, "\n", { plain = true, trimempty = true })
    local bufnr, winnr       = vim.lsp.util.open_floating_preview(
        lines,
        "markdown", -- or "plaintext"
        {
            focusable  = false,
            border     = "rounded",
            max_width  = 80,
            max_height = 15,
        }
    )
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].buftype    = "nofile"
    vim.wo[winnr].wrap       = true
    local aug                = vim.api.nvim_create_augroup("LoopPlugin_ToolHoverClose", { clear = true })
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group    = aug,
        once     = true,
        callback = function()
            if vim.api.nvim_win_is_valid(winnr) then
                vim.api.nvim_win_close(winnr, true)
            end
        end,
    })
end

---@param text string
---@param opts keystone.floatwin.FloatwinOpts?
function M.open(text, opts)
    opts = opts or {}
    if opts.is_hover then
        _open_hoverwindow(text)
        return
    end

    if _current_win and vim.api.nvim_win_is_valid(_current_win) then
        vim.api.nvim_win_close(_current_win, true)
    end

    local lines = vim.split(text, "\n", { trimempty = false })
    local ui_width = vim.o.columns
    local ui_height = vim.o.lines
    local max_w = math.floor(ui_width * 0.8)
    local max_h = math.floor(ui_height * 0.8)
    local content_w = 30
    for _, line in ipairs(lines) do
        content_w = math.max(content_w, vim.fn.strwidth(line))
    end

    local win_width = math.min(content_w + 2, max_w)
    local win_height = math.min(#lines, max_h)

    ---@type vim.api.keyset.win_config
    local win_opts = {
        width = win_width,
        height = win_height,
        style = "minimal",
        border = "rounded",
        title_pos = "center",
    }
    if opts and opts.title then
        win_opts.title = " " .. tostring(opts.title) .. " "
    end

    if opts.at_cursor then
        win_opts.relative = "cursor"
        win_opts.row = 1 -- One line below cursor
        win_opts.col = 0
    else
        win_opts.relative = "editor"
        win_opts.row = math.floor((ui_height - win_height) / 2)
        win_opts.col = math.floor((ui_width - win_width) / 2)
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    local win = vim.api.nvim_open_win(buf, true, win_opts)
    _current_win = win
    vim.wo[win].wrap = false
    vim.wo[win].winfixbuf = true

    if opts.is_markdown then
        vim.bo[buf].filetype = "markdown"
        local ok, _ = pcall(vim.treesitter.start, buf, "markdown")
        if not ok then
            vim.bo[buf].syntax = "on"
        end
        vim.wo[win].conceallevel = 3
        vim.wo[win].concealcursor = "nv"
    end
    local function close_modal()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
        _current_win = nil
    end

    local key_opts = { buffer = buf, silent = true }
    vim.keymap.set("n", "q", close_modal, key_opts)
    vim.keymap.set("n", "<Esc>", close_modal, key_opts)

    vim.api.nvim_create_autocmd("WinLeave", {
        group = debug_win_augroup,
        once = true,
        callback = close_modal,
    })

    if opts.move_to_bot then
        vim.api.nvim_win_call(win, function()
            local b = vim.api.nvim_win_get_buf(0)
            local l = vim.api.nvim_buf_line_count(b)
            vim.api.nvim_win_set_cursor(0, { l, 0 })
        end)
    end
end

return M
