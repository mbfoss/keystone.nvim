local M = {}

---@class keystone.utils.inputwin.Opts
---@field prompt? string
---@field default_text? string
---@field default_width? number
---@field row_offset? number
---@field col_offset? number
---@field completions? string[]
---@field validate? fun(content:string):boolean,string?
---@
---@param opts keystone.utils.inputwin.Opts
---@param on_confirm fun(value: string|nil)
function M.input_at_cursor(opts, on_confirm)
    local prev_win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)
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

    local col = #initial_text
    vim.api.nvim_win_set_cursor(win, { 1, col })
    vim.schedule(function()
        if vim.api.nvim_get_current_win() == win then
            vim.api.nvim_win_call(win, function()
                vim.cmd("startinsert!")
            end)
        end
    end)
    if opts.completions and #opts.completions > 0 then
        vim.bo[buf].omnifunc = 'v:lua.require("keystone.utils.inputwin")._complete'
        M._complete_cache = opts.completions
        M._complete_buf = buf
    end
    vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
        buffer = buf,
        callback = function()
            local line = vim.api.nvim_get_current_line()
            local new_width = math.max(min_width, vim.fn.strdisplaywidth(line) + 2)
            new_width = math.min(new_width, max_width)

            if new_width ~= current_width then
                current_width = new_width
                if vim.api.nvim_win_is_valid(win) then
                    vim.api.nvim_win_set_config(win, { width = current_width })
                end
            end
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
    vim.api.nvim_create_autocmd("TextChangedI", {
        buffer = buf,
        callback = function()
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
    local closed = false
    ---@param value string|nil
    local function close(value)
        if closed then return end
        if value and opts.validate then
            local validated, err_msg = opts.validate(value)
            if not validated and err_msg then
                vim.notify(err_msg)
                return
            end
        end
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
