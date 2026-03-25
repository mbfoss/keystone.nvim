local M = {}

local filetools = require("keystone.utils.file")

---@param winid number?
function M.get_window_text_width(winid)
    if not winid or winid == 0 then winid = vim.api.nvim_get_current_win() end
    local infos = vim.fn.getwininfo(winid)
    if not infos or #infos == 0 then
        return vim.o.columns - 3 -- fallback assumption
    end
    local info = infos[1]
    -- info.width is total width, info.textoff is the combined width of
    -- line numbers, sign columns, and fold columns.
    return info.width - info.textoff
end

function M.is_regular_buffer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end
    local buftype = vim.bo[bufnr].buftype
    local buflisted = vim.bo[bufnr].buflisted

    -- Exclude special buffer types
    if buftype ~= '' or not buflisted then
        return false
    end
    return true
end

---@param override (fun(winid:number):boolean?)?
---@return number window number
function M.get_regular_window(override)
    -- Helper function to check if a window is "regular"
    local function is_regular_win(winid)
        if override then
            local result = override(winid)
            if result == true or result == false then
                return result
            end
        end
        if not vim.api.nvim_win_is_valid(winid) then return false end
        local cfg = vim.api.nvim_win_get_config(winid)
        if cfg.relative ~= "" then return false end      -- skip popups
        if vim.wo[winid].winfixbuf then return false end -- skip fixed windows
        local bufnr = vim.api.nvim_win_get_buf(winid)
        return M.is_regular_buffer(bufnr)
    end

    -- Try current window first
    local cur_win = vim.api.nvim_get_current_win()
    if is_regular_win(cur_win) then
        return cur_win
    end

    local tabpage = vim.api.nvim_get_current_tabpage()
    local wins = vim.api.nvim_tabpage_list_wins(tabpage)
    -- Then loop over all other windows
    for _, winid in ipairs(wins) do
        if winid ~= cur_win and is_regular_win(winid) then
            return winid
        end
    end
    -- No regular window found; create a vertial split
    vim.cmd('vsplit')
    local new_win = vim.api.nvim_get_current_win()
    return new_win
end

---@return string|nil,number|nil
function M.get_current_file_and_line()
    local buf = vim.api.nvim_get_current_buf()
    if not M.is_regular_buffer(buf) then
        return
    end
    local file = vim.fn.expand("%:p")
    if file == "" then
        return
    end
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    return file, lnum
end

---@param winid integer
---@param line? integer 1‑based line number (nil = just open)
---@param col? integer 1‑based line number (nil = just open)
function M.set_cursor_pos(winid, line, col)
    if line and type(line) == 'number' and line > 0 then
        local bufnr = vim.api.nvim_win_get_buf(winid)
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end
        -- Clamp line to valid range
        local maxline = vim.api.nvim_buf_line_count(bufnr)
        line = math.min(line, maxline)

        -- Clamp col to valid range
        local line_length = #vim.api.nvim_buf_get_lines(bufnr, line - 1, line, true)[1]
        if col and type(col) == 'number' and col >= 0 then
            col = math.min(col, line_length)
        else
            col = 0
        end
        vim.api.nvim_win_set_cursor(winid, { line, col })
    end
end

---@param filepath string
---@param line? integer 1‑based line number (nil = just open)
---@param col? integer 1‑based line number (nil = just open)
---@return number winid or -1
---@return number bufnr or -1
function M.smart_open_file(filepath, line, col)
    if not filepath or filepath == "" then return -1, -1 end
    -- Normalize filepath to handle relative paths
    local full_path = vim.fn.fnamemodify(filepath, ':p')
    -- Check all windows for the file
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        local bufnr = vim.api.nvim_win_get_buf(winid)
        local buf_path = vim.api.nvim_buf_get_name(bufnr)
        if buf_path == full_path and vim.api.nvim_win_is_valid(winid) then
            -- Activate the window with the file
            vim.api.nvim_set_current_win(winid)
            M.set_cursor_pos(winid, line, col)
            return winid, bufnr
        end
    end

    local winid = M.get_regular_window()
    vim.api.nvim_set_current_win(winid)

    vim.cmd.edit(vim.fn.fnameescape(filepath))
    M.set_cursor_pos(winid, line, col)
    local bufnr = vim.api.nvim_win_get_buf(winid)

    return winid, bufnr
end

---@param filepath  string
---@return boolean success
---@return string content or error
function M.read_file_or_buffer(filepath)
    local full_path = vim.fn.fnamemodify(filepath, ":p")
    local bufnr = vim.fn.bufnr(full_path, false) -- false = don't create

    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        return true, table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
    end
    return filetools.read_content(full_path)
end

---@param bufnr number
---@return number winid
function M.smart_open_buffer(bufnr)
    -- Check if the buffer is already displayed in any visible window
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(winid) == bufnr then
            -- Buffer is already visible, just return this window
            vim.api.nvim_set_current_win(winid)
            return winid
        end
    end
    -- Buffer not visible in any window, find or create an empty window
    local winid = M.get_regular_window()
    vim.api.nvim_set_current_win(winid)
    vim.api.nvim_win_set_buf(winid, bufnr)
    return winid
end

---@param winid number
---@param text string
function M.move_to_first_occurence(winid, text)
    local bufnr = vim.api.nvim_win_get_buf(winid)
    vim.api.nvim_win_set_cursor(winid, { 1, 0 })
    local line = vim.fn.search(text)
    if line > 0 then
        -- Move cursor to the **end of the word** (0-indexed)
        local line_text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
        local s, e = line_text:find(text, 1, true) -- get start and end column
        if s and e then
            vim.api.nvim_win_set_cursor(winid, { line, e })
        end
    end
end

---@param winid number
---@param text string
function M.move_to_last_occurence(winid, text)
    local bufnr = vim.api.nvim_win_get_buf(winid)
    vim.api.nvim_win_set_cursor(winid, { vim.api.nvim_buf_line_count(bufnr), 0 })
    local line = vim.fn.search(text, 'bW') -- 'b' = backwards, 'W' = whole word
    if line > 0 then
        -- Move cursor to the **end of the word** (0-indexed)
        local line_text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
        local s, e = line_text:find(text, 1, true) -- get start and end column
        if s and e then
            vim.api.nvim_win_set_cursor(winid, { line, e })
        end
    end
end

function M.disable_insert_mappings(buf)
    -- === 1. Disable direct insert-mode entry keys ===
    local insert_keys = {
        'i', 'a', 'o', 'I', 'A', 'O',
        'c', 'cc', 'C', 's', 'S', 'R', 'gi', 'gI', '.'
    }

    for _, key in ipairs(insert_keys) do
        vim.api.nvim_buf_set_keymap(buf, 'n', key, '<Nop>', { noremap = true, silent = true })
    end

    -- Visual mode: disable change/delete that enter insert
    local visual_keys = { 'c', 's', 'C', 'S', 'R' }
    for _, key in ipairs(visual_keys) do
        vim.api.nvim_buf_set_keymap(buf, 'v', key, '<Nop>', { noremap = true, silent = true })
    end
end

---@param msg string
---@param default_yes boolean
---@param callback fun(confirmed: boolean|nil)
function M.confirm_action(msg, default_yes, callback)
    local choices = "&Yes\n&No"
    local default = default_yes and 1 or 2

    local ok, choice = pcall(vim.fn.confirm, msg, choices, default)
    if not ok then
        callback(nil)
        return
    end
    if choice == 1 then
        callback(true)
    elseif choice == 2 then
        callback(false)
    else
        callback(nil)
    end
end

---@param c1 number
---@param c2 number
---@param alpha number
---@return string
function M.blend_colors(c1, c2, alpha)
    local r1 = bit.rshift(c1, 16)
    local g1 = bit.band(bit.rshift(c1, 8), 0xFF)
    local b1 = bit.band(c1, 0xFF)

    local r2 = bit.rshift(c2, 16)
    local g2 = bit.band(bit.rshift(c2, 8), 0xFF)
    local b2 = bit.band(c2, 0xFF)

    local r = math.floor(r1 * (1 - alpha) + r2 * alpha)
    local g = math.floor(g1 * (1 - alpha) + g2 * alpha)
    local b = math.floor(b1 * (1 - alpha) + b2 * alpha)

    return string.format("#%02x%02x%02x", r, g, b)
end

---@param winid number
---@return boolean
function M.is_win_full_height(winid)
    if not vim.api.nvim_win_is_valid(winid) then return false end
    local win_height = vim.api.nvim_win_get_height(winid)
    local total_height = vim.o.lines - vim.o.cmdheight
    if vim.o.laststatus > 0 then
        total_height = total_height - 1 -- account for statusline
    end
    return win_height == total_height
end

return M
