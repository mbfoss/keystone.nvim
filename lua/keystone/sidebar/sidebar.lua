local M = {}

local views = require("keystone.sidebar.views")

local KEY_MARKER = "LoopPlugin_SideWin"
local INDEX_MARKER = "LoopPlugin_SideWinlIdx"

local _layout_augroup = vim.api.nvim_create_augroup("keystone_sidebar_layout", { clear = true })
local _buffers_augroup = vim.api.nvim_create_augroup("keystone_sidebar_buffer", { clear = true })


---@class keystone.SidebarPresetView
---@field id string
---@field name string
---@field ratio number?

---@class keystone.SidebarPresetData
---@field name string
---@field views keystone.SidebarPresetView[]

---@type table<string, keystone.SidebarPresetData>
local _presets = {}

---@type string?
local _active_preset_id = nil

---@type {buffer:boolean}
local _active_buffers = {}

local _state = {
    width_ratio = nil,
    ---@type table<string, number[]> -- Maps preset ID -> array of vertical ratios
    ratios = {},
    ---@type table<string, table[]> -- Maps preset ID -> array of view-specific states
    view_states = {}
}

local function _is_managed_window(win)
    if not vim.api.nvim_win_is_valid(win) then
        return false
    end

    local ok, val = pcall(function()
        return vim.w[win][KEY_MARKER]
    end)

    return ok and val == true
end


local function _get_window_index(win)
    local ok, val = pcall(function()
        return vim.w[win][INDEX_MARKER]
    end)

    return ok and val or nil
end


local function _get_managed_windows()
    local wins = {}

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if _is_managed_window(win) then
            table.insert(wins, win)
        end
    end

    table.sort(wins, function(a, b)
        return (_get_window_index(a) or 1) < (_get_window_index(b) or 1)
    end)

    return wins
end

---@param win number
local function _set_custom_win_flags(win)
    vim.wo[win].wrap = false
    vim.wo[win].spell = false
    vim.wo[win].winfixbuf = true
    vim.wo[win].winfixheight = true
    vim.wo[win].winfixwidth = true
end
local function _are_windows_stacked_vertically(wins)
    if #wins <= 1 then return true end

    local first_win_pos = vim.api.nvim_win_get_position(wins[1])
    local first_col = first_win_pos[2] -- [row, col]

    for i = 2, #wins do
        local pos = vim.api.nvim_win_get_position(wins[i])
        if pos[2] ~= first_col then
            return false
        end
    end
    return true
end

local function _save_current_layout_to_state()
    if not _active_preset_id then return end
    local wins = _get_managed_windows()
    if #wins == 0 then return end
    if not _are_windows_stacked_vertically(wins) then return end

    local preset = _presets[_active_preset_id]
    if not preset then return end

    local total_w = vim.o.columns
    local total_h = vim.o.lines - vim.o.cmdheight
    local actual_w = vim.api.nvim_win_get_width(wins[1])
    if actual_w == total_w then return end

    _state.width_ratio = actual_w / total_w
    local current_ratios = {}
    local current_view_states = {}

    for i, win in ipairs(wins) do
        local actual_h = vim.api.nvim_win_get_height(win)
        table.insert(current_ratios, actual_h / total_h)
        local view_def = preset.views[i]
        local state = nil
        if view_def then
            local viewinfo = views.get_view_info(view_def.id)
            if viewinfo and viewinfo.provider and viewinfo.provider.get_state then
                state = viewinfo.provider.get_state()
            end
        end
        table.insert(current_view_states, state)
    end

    _state.ratios[_active_preset_id] = current_ratios
    _state.view_states[_active_preset_id] = current_view_states
end

local function _apply_ratios()
    if not _active_preset_id then return end
    local preset = _presets[_active_preset_id]
    if not preset then
        return
    end

    local windows = _get_managed_windows()
    if #preset.views ~= #windows then
        return
    end

    if not _are_windows_stacked_vertically(windows) then
        return
    end

    local active_ratios = _state.ratios[_active_preset_id]

    local width_ratio = _state.width_ratio or 0.2
    local ratios = {}
    for i, view in ipairs(preset.views) do
        local r = (active_ratios and active_ratios[i]) or view and view.ratio or 0
        table.insert(ratios, r)
    end


    local num_wins = #windows
    if num_wins == 0 then return end
    local total_ui_width = vim.o.columns
    local target_width = math.floor(total_ui_width * (width_ratio or .2))

    if num_wins == 1 then
        vim.api.nvim_win_set_width(windows[1], target_width)
        return
    end
    local total_ui_height = vim.o.lines - vim.o.cmdheight -- account for status/cmd line
    local fixed_ratio_sum = 0
    local nil_count = 0

    for _, r in ipairs(ratios) do
        if r and r > 0 then
            fixed_ratio_sum = fixed_ratio_sum + r
        else
            nil_count = nil_count + 1
        end
    end
    local remaining_ratio = math.max(0, 1 - fixed_ratio_sum)
    local ratio_per_nil = nil_count > 0 and (remaining_ratio / nil_count) or 0
    for i = num_wins, 1, -1 do
        local win = windows[i]
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_set_width(win, target_width)
            local r = ratios[i]
            if not r or r <= 0 then r = ratio_per_nil end
            local target_height = math.floor(total_ui_height * r)
            vim.api.nvim_win_set_height(win, math.max(target_height, 1))
        end
    end
end

---@return boolean
local function _is_layout_valid()
    local windows = _get_managed_windows()
    local num_managed = #windows
    if num_managed <= 0 then return false end
    local _, sidebar_col = unpack(vim.api.nvim_win_get_position(windows[1]))
    local sidebar_width = vim.api.nvim_win_get_width(windows[1])
    if sidebar_col ~= 0 then return false end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local is_managed = _is_managed_window(win)
        local _, win_col = unpack(vim.api.nvim_win_get_position(win))
        local win_width = vim.api.nvim_win_get_width(win)
        if is_managed then
            if win_col ~= 0 or win_width ~= sidebar_width then
                return false
            end
        else
            if win_col == 0 then
                return false
            end
        end
    end
    return true
end

local function _fix_layout()
    if _is_layout_valid() then return end
    local windows = _get_managed_windows()
    if #windows <= 0 then return end
    local anchor_win = windows[1]
    local width = vim.api.nvim_win_get_width(anchor_win)
    vim.api.nvim_win_call(anchor_win, function()
        vim.cmd(("vertical resize %d | wincmd H"):format(width))
    end)
    local last_win = anchor_win
    for i = 2, #windows do
        local win = windows[i]
        vim.fn.win_splitmove(win, last_win, { vertical = false, rightbelow = true })
        last_win = win
    end
    _apply_ratios()
end

local function _destroy_buffers()
    for bufnr, _ in pairs(_active_buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end
    _active_buffers = {}
end


local _init_done = false
local function _ensure_init()
    if _init_done then return end
    _init_done = true
    local tree
    ---@type keystone.ViewProvider
    local provider = {
        create_buffer = function(state)
            if not tree then
                local FileTree = require("keystone.sidebar.FileTree")
                tree = FileTree:new()
            end
            tree:set_persistent_state(state)
            local buf = tree:get_compbuffer():get_or_create_buf()
            return buf
        end,
        get_state = function()
            return tree and tree:get_persistent_state() or {}
        end
    }
    views.register_view("builtin:files", "files", provider)
    M.register_preset("builtin:files", "files",
        { { id = "builtin:files", name = "files", ratio = 1 } }
    )
end

local function _hide()
    local wins = _get_managed_windows()
    if #wins > 0 then
        _save_current_layout_to_state()
    end
    vim.api.nvim_clear_autocmds({ group = _layout_augroup })
    for _, win in ipairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win)
        end
    end
    _destroy_buffers()
end


---@param id string?
---@return boolean
local function _show(id)
    _ensure_init()
    if not id then
        id = _active_preset_id
    end
    if not id then
        return false
    end
    local preset = _presets[id]

    if not preset then
        return false
    end

    local wins = _get_managed_windows()

    if not id or id == _active_preset_id then
        if #wins > 0 then
            return true
        end
    end

    if #wins > 0 then
        _hide()
    end

    _active_preset_id = id
    local saved_states = _state.view_states[id] or {}

    local buffers = {}
    for i, view_def in ipairs(preset.views) do
        local viewinfo = views.get_view_info(view_def.id)
        if viewinfo and viewinfo.provider then
            local bufnr = viewinfo.provider.create_buffer(saved_states[i])
            if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
                table.insert(buffers, bufnr)
            end
        end
    end
    if #buffers == 0 then
        return false
    end
    vim.api.nvim_clear_autocmds({ group = _buffers_augroup })
    for i, buf in ipairs(buffers) do
        _active_buffers[buf] = true
        vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
            buffer = buf,
            once = true,
            group = _buffers_augroup,
            callback = function(args)
                _active_buffers[args.buf] = nil
            end,
        })
    end
    local original = vim.api.nvim_get_current_win()
    vim.cmd("topleft 1vsplit")
    local first = vim.api.nvim_get_current_win()
    local windows = { first }
    for _ = 2, #buffers do
        vim.cmd("belowright split")
        table.insert(windows, vim.api.nvim_get_current_win())
    end
    for i, win in ipairs(windows) do
        _set_custom_win_flags(win)
        vim.w[win][KEY_MARKER] = true
        vim.w[win][INDEX_MARKER] = i
    end
    for i, buf in ipairs(buffers) do
        local win = windows[i]
        vim.wo[win].winfixbuf = false
        vim.api.nvim_win_set_buf(win, buf)
        vim.wo[win].winfixbuf = true
    end
    _apply_ratios()
    if vim.api.nvim_win_is_valid(original) then
        vim.api.nvim_set_current_win(original)
    end
    vim.api.nvim_clear_autocmds({ group = _layout_augroup })
    vim.api.nvim_create_autocmd("VimResized", {
        group = _layout_augroup,
        callback = function()
            _apply_ratios()
        end,
    })
    vim.api.nvim_create_autocmd("QuitPre", {
        group = _layout_augroup,
        callback = function()
            _save_current_layout_to_state()
        end,
    })
    return true
end

---@param id string
---@param name string
---@param view_list keystone.SidebarPresetView[]
function M.register_preset(id, name, view_list)
    assert(not _presets[id], "preset id already registered: " .. tostring(id))
    _presets[id] = {
        name = name,
        views = view_list,
    }
    if not _active_preset_id then
        _active_preset_id = id
    end
    return id
end

---@return boolean
function M.have_views()
    return next(_presets) ~= nil
end

---@return string[]
function M.preset_names()
    local names = {}
    local name_counts = {}
    for _, p in pairs(_presets) do
        name_counts[p.name] = (name_counts[p.name] or 0) + 1
    end
    for id, p in pairs(_presets) do
        if name_counts[p.name] > 1 then
            table.insert(names, id)
        else
            table.insert(names, p.name)
        end
    end
    table.sort(names)
    return names
end

---@param name string?
function M.show_by_name(name)
    if not name then
        return _show()
    end
    local name_counts = {}
    for _, p in pairs(_presets) do
        name_counts[p.name] = (name_counts[p.name] or 0) + 1
    end
    for id, info in pairs(_presets) do
        if name_counts[info.name] == 1 then
            if name == info.name then
                return _show(id)
            end
        else
            if name == id then
                return _show(name)
            end
        end
    end
    vim.notify("[keystone.nvim] Invalid sidebar name: " .. tostring(name), vim.log.levels.WARN)
end

---@param id string
function M.show_by_id(id)
    if id and _presets[id] then
        _show(id)
    else
        vim.notify("[keystone.nvim] Invalid sidebar id: " .. tostring(id), vim.log.levels.WARN)
    end
end

function M.is_visible()
    local wins = _get_managed_windows()
    return #wins > 0
end

function M.hide()
    _hide()
end

function M.toggle()
    local wins = _get_managed_windows()
    if #wins > 0 then
        _hide()
    else
        _show()
    end
end

function M.fix_layout()
    _fix_layout()
end

return M
