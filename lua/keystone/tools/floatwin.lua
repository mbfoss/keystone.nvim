---@class keystone.tools.floatwin
---@field _complete_cache? string[]
---@field _complete_buf? integer
local M = {}

local debug_win_augroup = vim.api.nvim_create_augroup("KeystonePlugin_ModalWin", { clear = true })
local _current_win = nil


---@class keystone.floatwin.CenteredWinOpts
---@field width number
---@field height number
---@field border string?
---@field title string?

---@class keystone.floatwin.FloatwinOpts
---@field title? string
---@field at_cursor? boolean
---@field move_to_bot? boolean

---@class keystone.floatwin.InputOpts
---@field prompt? string
---@field default_text? string
---@field default_width? number
---@field row_offset? number
---@field col_offset? number
---@field completions? string[]

---@class keystone.floatwin.MultilineInputOpts
---@field prompt? string
---@field default_text? string
---@field filetype? string
---@field validate? fun(content:string):boolean,string?

---@param buf number
---@param opts keystone.floatwin.CenteredWinOpts
function M.open_centered_window(buf, opts)
    opts = opts or {}

    -- Validate required options
    if not opts.width or not opts.height then
        error("width and height are required")
    end

    -- Editor size
    local editor_width = vim.o.columns
    local editor_height = vim.o.lines - vim.o.cmdheight -- subtract command line

    -- Calculate centered position
    local row = math.floor((editor_height - opts.height) / 2)
    local col = math.floor((editor_width - opts.width) / 2)

    -- Open floating window
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = row,
        col = col,
        width = opts.width,
        height = opts.height,
        style = "minimal",
        border = opts.border or "rounded",
        title = opts.title or "",
        title_pos = "center", -- optional: title in center
    })
    return win
end

---@param text string
function M.show_tooltip(text)
    local lines              = vim.split(text, "\n", { plain = true, trimempty = true })
    -- This mimics what LSP hover does
    local bufnr, winnr       = vim.lsp.util.open_floating_preview(
        lines,
        "markdown", -- or "plaintext"
        {
            focusable  = false,
            border     = "rounded",
            max_width  = 80,
            max_height = 15,
            -- You can add more: title = "Tooltip", ...
        }
    )
    -- Optional: make it feel more like real hover
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].buftype    = "nofile"
    vim.wo[winnr].wrap       = true

    -- Auto-close on cursor move (very common pattern)
    local aug = vim.api.nvim_create_augroup("KeystonePlugin_ToolHoverClose", { clear = true })
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
function M.show_floatwin(text, opts)
    opts = opts or {}
    if _current_win and vim.api.nvim_win_is_valid(_current_win) then
        vim.api.nvim_win_close(_current_win, true)
    end

    local lines = vim.split(text, "\n", { trimempty = false })

    -- 1. Calculate UI Constraints
    local ui_width = vim.o.columns
    local ui_height = vim.o.lines
    local max_w = math.floor(ui_width * 0.8)
    local max_h = math.floor(ui_height * 0.8)

    -- 2. Calculate Content Dimensions
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
        -- Cursor Relative Layout
        win_opts.relative = "cursor"
        win_opts.row = 1 -- One line below cursor
        win_opts.col = 0
    else
        -- Central Editor Layout
        win_opts.relative = "editor"
        win_opts.row = math.floor((ui_height - win_height) / 2)
        win_opts.col = math.floor((ui_width - win_width) / 2)
    end

    -- 4. Create Buffer
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"

    -- 5. Open Window
    local win = vim.api.nvim_open_win(buf, true, win_opts)
    _current_win = win

    -- 6. Window-local options
    vim.wo[win].wrap = false
    vim.wo[win].winfixbuf = true

    -- 7. Modal Logic
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
        buffer = buf,
        callback = close_modal,
        once = true,
    })

    if opts.move_to_bot then
        vim.api.nvim_win_call(win, function()
            local b = vim.api.nvim_win_get_buf(0)
            local l = vim.api.nvim_buf_line_count(b)
            vim.api.nvim_win_set_cursor(0, { l, 0 })
        end)
    end
end

-- ===================================================================
-- Single-line input function (existing behavior)
-- ===================================================================
---@param opts keystone.floatwin.InputOpts
---@param on_confirm fun(value: string|nil)
function M.input_at_cursor(opts, on_confirm)
    local prev_win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)

    -- Buffer setup
    local buf_opts = {
        buftype = "nofile",
        bufhidden = "wipe",
        swapfile = false,
        undolevels = -1
    }
    for k, v in pairs(buf_opts) do vim.bo[buf][k] = v end

    local initial_text = opts.default_text or ""
    if initial_text:match("\n") then initial_text = "" end

    local min_width = math.max(opts.default_width or 20, vim.fn.strdisplaywidth(opts.prompt or "") + 2)
    local max_width = math.floor(vim.o.columns * 0.8)
    local current_width = math.max(min_width, 40)
    current_width = math.min(current_width, max_width)

    local min_height = 1
    local max_height = math.floor(vim.o.lines * 0.8)
    local current_height = 1

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "cursor",
        row = opts.row_offset or 1,
        col = opts.col_offset or 0,
        width = current_width,
        height = 1,
        style = "minimal",
        border = "rounded",
        title = opts.prompt and (" %s "):format(opts.prompt) or nil
    })

    vim.wo[win].wrap = true
    vim.wo[win].winfixbuf = true
    vim.wo[win].winhighlight = "Normal:Normal,NormalNC:Normal,EndOfBuffer:Normal,FloatBorder:Normal"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { initial_text })

    if initial_text == "" then
        vim.schedule(function()
            if vim.api.nvim_get_current_win() == win then
                vim.cmd("startinsert!")
            end
        end)
    end

    -- Setup completion if completions provided
    if opts.completions and #opts.completions > 0 then
        vim.bo[buf].omnifunc = 'v:lua.require("keystone.tools.floatwin")._complete'
        M._complete_cache = opts.completions
        M._complete_buf = buf
    end

    -- AUTO-RESIZE LOGIC
    vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
        buffer = buf,
        callback = function()
            local line = vim.api.nvim_get_current_line()
            -- Width
            local new_width = math.max(min_width, vim.fn.strdisplaywidth(line) + 2)
            new_width = math.min(new_width, max_width)

            if new_width ~= current_width then
                current_width = new_width
                if vim.api.nvim_win_is_valid(win) then
                    vim.api.nvim_win_set_config(win, { width = current_width })
                end
            end

            -- Height (wrap-aware)
            if vim.api.nvim_win_is_valid(win) and vim.wo[win].wrap then
                local display_width = math.max(1, current_width - 2) -- borders
                local needed_rows = math.ceil(vim.fn.strdisplaywidth(line) / display_width)
                local new_height = math.min(math.max(needed_rows, min_height), max_height)

                if new_height ~= current_height then
                    current_height = new_height
                    vim.api.nvim_win_set_config(win, { height = current_height })
                end
            end
        end
    })

    -- COMPLETION TRIGGER
    vim.api.nvim_create_autocmd("TextChangedI", {
        buffer = buf,
        callback = function()
            -- Completion
            if opts.completions and #opts.completions > 0 then
                local line = vim.api.nvim_get_current_line()
                local col = vim.fn.col(".")
                local base = line:sub(1, col - 1)
                local matches = M._complete(1, base)
                if matches and #matches > 0 then
                    vim.fn.complete(col, matches)
                end
            end
        end
    })

    -- ---------------- Close logic ----------------
    local closed = false
    ---@param value string|nil
    local function close(value)
        if closed then return end
        closed = true
        vim.cmd("stopinsert")
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
        if vim.api.nvim_win_is_valid(prev_win) then
            vim.api.nvim_set_current_win(prev_win)
        end
        vim.schedule(function() on_confirm(value) end)
    end

    -- ---------------- Keymaps ----------------
    local kopts = { buffer = buf, nowait = true }
    vim.keymap.set({ "i", "n" }, "<CR>", function() close(vim.api.nvim_get_current_line()) end, kopts)
    vim.keymap.set("i", "<C-c>", function() close(nil) end, kopts)
    vim.keymap.set("n", "<Esc>", function() close(nil) end, kopts)
    if opts.completions and #opts.completions > 0 then
        vim.keymap.set("i", "<C-x><C-o>", function()
            vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<C-x><C-o>", true, true, true), "n")
        end, kopts)
    end

    vim.api.nvim_create_autocmd("WinLeave", {
        once = true,
        callback = function() close(nil) end,
    })
end

---@param opts keystone.floatwin.MultilineInputOpts
---@param on_confirm fun(value: string|nil)
function M.input_multiline(opts, on_confirm)
    local prev_win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)

    -- Buffer setup
    local buf_opts = {
        buftype = "nofile",
        bufhidden = "wipe",
        swapfile = false,
        filetype = opts.filetype
    }
    for k, v in pairs(buf_opts) do vim.bo[buf][k] = v end

    local initial_text = opts.default_text or ""
    local have_initial_text = initial_text ~= ""
    local initial_lines = vim.split(initial_text, "\n", { plain = true })
    if #initial_lines == 0 then initial_lines = { "" } end

    local title = opts.prompt and (" %s [Ctrl-G to confirm, Ctrl-C to cancel] "):format(opts.prompt) or nil
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.8)

    local win = M.open_centered_window(buf, {
        width = width,
        height = height,
        title = title,
    })

    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].scrolloff = 0
    vim.wo[win].winhighlight =
    "Normal:Normal,NormalNC:Normal,EndOfBuffer:Normal,FloatBorder:Normal"

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)

    if not have_initial_text then
        vim.schedule(function()
            if vim.api.nvim_get_current_win() == win then
                vim.cmd("startinsert!")
            end
        end)
    end

    -- ---------------- Close logic ----------------
    local closed = false
    local function confirm_discard()
        local answer = vim.fn.confirm("Discard changes?", "&Yes\n&No", 2)
        return answer == 1
    end

    ---@param value string?
    local function close(value)
        if value and opts.validate then
            local validated, err_msg = opts.validate(value)
            if not validated then
                vim.notify(err_msg or "Validation failed")
                return
            end
        end
        if closed then return end
        closed = true

        vim.cmd("stopinsert")
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
        if vim.api.nvim_win_is_valid(prev_win) then
            vim.api.nvim_set_current_win(prev_win)
        end
        if value then
            vim.schedule(function() on_confirm(value) end)
        end
    end

    local function try_close()
        local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        if table.concat(current_lines, "\n") ~= initial_text then
            if confirm_discard() then
                close(nil)
            else
                vim.schedule(function()
                    vim.api.nvim_set_current_win(win)
                    vim.cmd("startinsert!")
                end)
            end
        else
            close(nil)
        end
    end

    local save_and_close = function()
        close(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    end
    -- ---------------- Keymaps ----------------
    local kopts = { buffer = buf, nowait = true }

    -- Enter = newline
    vim.keymap.set("i", "<CR>", "<CR>", kopts)

    -- Confirm = Ctrl-g
    vim.keymap.set({ "i", "n" }, "<C-g>", save_and_close, kopts)
    vim.keymap.set({ "n", "n" }, "<C-g>", save_and_close, kopts)

    -- Cancel = Ctrl-C
    vim.keymap.set("i", "<C-c>", try_close, kopts)
    vim.keymap.set("n", "<C-c>", try_close, kopts)

    -- Esc just leaves insert mode
    vim.keymap.set("i", "<Esc>", "<Esc>", kopts)

    -- Window leave = try close with confirmation
    vim.api.nvim_create_autocmd("WinLeave", {
        once = true,
        callback = function()
            if not closed then
                try_close()
            end
        end,
    })
end

---@param findstart integer
---@param base string
---@return string[]
function M._complete(findstart, base)
    local completions = M._complete_cache or {}
    local matches = {}
    for _, item in ipairs(completions) do
        if vim.startswith(item, base) then
            table.insert(matches, item)
        end
    end
    return matches
end

return M
