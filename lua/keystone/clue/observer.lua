--- Passive key observer driving the clue window.
---
--- Rather than mapping trigger keys and consuming input, the observer watches
--- the physical key stream via `vim.on_key` and only *mirrors* it: Neovim still
--- resolves and executes every key natively (counts, registers, operators and
--- mappings all behave normally). When the pending sequence starts with a
--- configured trigger and is a prefix of one or more mappings, the clue window
--- is shown — synchronously, with no timer, so no spurious `K_EVENT` is injected
--- into a pending mapping. It is torn down when the sequence resolves, breaks,
--- the mode changes, or `<Esc>` is pressed.
local keys = require("keystone.clue.keys")
local window = require("keystone.clue.window")

local M = {}

--- Shared config table, set by `keystone.clue`.
---@type table?
M.config = nil

local _ESC = "\27"

--- on_key / autocmd registration
local _ns ---@type integer?
local _augroup ---@type integer?

--- trigger lookups, built from `config.triggers`
local _begin_any = {} ---@type table<string, boolean> any-mode fast pre-check
local _begin_mode = { n = {}, x = {} } ---@type table<string, table<string, boolean>>
local _clues_by_mode = { n = {}, x = {} } ---@type table<string, keystone.clue.Clue[]>

--- current interaction state
local _active = false
local _raw = "" ---@type string pending physical bytes
local _mode = nil ---@type string? "n" | "x"
local _maps = {} ---@type keystone.clue.Map[]
local _handle = nil ---@type keystone.clue.WinHandle?

--- While a clue is pending we disable `'timeout'` so Neovim waits indefinitely
--- for the next key (instead of resolving the prefix after `'timeoutlen'`),
--- keeping the window up until the user actually presses a key. The previous
--- value is restored on teardown.
local _timeout_held = false
local _saved_timeout = nil ---@type boolean?

--- Disable `'timeout'` for the duration of an interaction so Neovim keeps
--- waiting for the next key; remember the value to restore.
local function _hold_timeout()
    if not _timeout_held then
        _saved_timeout = vim.o.timeout
        _timeout_held = true
    end
    vim.o.timeout = false
end

local function _release_timeout()
    if _timeout_held then
        vim.o.timeout = _saved_timeout
        _timeout_held = false
    end
end

local function _reset()
    _release_timeout()
    if _handle then
        window.close(_handle)
        _handle = nil
    end
    _active = false
    _raw = ""
    _mode = nil
    _maps = {}
end

---@return string
local function _title()
    return " " .. vim.fn.keytrans(_raw) .. " "
end

local function _render()
    if not _active then
        return
    end
    local entries = keys.clues(_maps, _raw, M.config._groups)
    if #entries == 0 then
        if _handle then
            window.close(_handle)
            _handle = nil
        end
        return
    end
    if _handle and vim.api.nvim_win_is_valid(_handle.win) then
        window.update(_handle, entries, _title(), M.config.win)
    else
        _handle = window.open(entries, _title(), M.config.win)
    end
end

---@param mode string "n" | "x"
---@param typed string
local function _begin(mode, typed)
    _reset()
    local maps = keys.collect(mode, _clues_by_mode[mode])
    if not keys.has_children(maps, typed) then
        return -- nothing follows this trigger; leave it to Neovim
    end
    _active = true
    _mode = mode
    _raw = typed
    _maps = maps
    _hold_timeout()
    _render()
end

--- Map a raw mode string from `nvim_get_mode` to a handled family, or nil.
---@param m string
---@return string?
local function _family(m)
    local base = m:sub(1, 1)
    if base == "n" then
        return "n"
    elseif base == "v" or base == "V" or base == "\22" then
        return "x"
    end
    return nil
end

---@param typed string physically typed bytes ("" for mapped / fed keys)
local function _handle_key(typed)
    if typed == nil or typed == "" then
        return
    end

    if not _active then
        if not _begin_any[typed] then
            return
        end
        local mode = _family(vim.api.nvim_get_mode().mode)
        if mode and _begin_mode[mode][typed] then
            _begin(mode, typed)
        end
        return
    end

    if typed == _ESC then
        _reset()
        return
    end

    local mode = _family(vim.api.nvim_get_mode().mode)
    if mode ~= _mode then
        _reset()
        return
    end

    local next_raw = _raw .. typed
    if keys.has_children(_maps, next_raw) then
        _raw = next_raw
        _render()
    elseif keys.exact(_maps, next_raw) then
        -- a complete mapping; Neovim executes it
        _reset()
    else
        -- the sequence broke; this key may itself start a new one
        _reset()
        if _begin_any[typed] and _begin_mode[mode][typed] then
            _begin(mode, typed)
        end
    end
end

--- `on_key` callback. Wraps `_handle_key` so a transient error resets state but
--- never throws — an error here would make Neovim remove the listener and
--- silently disable clue for the whole session.
---@param _key string resolved key (unused)
---@param typed string physically typed bytes ("" for mapped / fed keys)
local function _on_key(_key, typed)
    local ok = pcall(_handle_key, typed)
    if not ok then
        _reset()
    end
end

--- Build the begin lookups and per-mode virtual clue lists from the config.
local function _build()
    _begin_any = {}
    _begin_mode = { n = {}, x = {} }
    _clues_by_mode = { n = {}, x = {} }

    for _, t in ipairs(M.config.triggers or {}) do
        local mode = (t.mode == "x" or t.mode == "v") and "x" or "n"
        local raw = keys.to_raw(t.keys)
        if raw ~= "" then
            _begin_mode[mode][raw] = true
            _begin_any[raw] = true
        end
    end

    local clues = {} ---@type keystone.clue.Clue[]
    if M.config.builtin_clues then
        vim.list_extend(clues, require("keystone.clue.builtin"))
    end
    vim.list_extend(clues, M.config.clues or {})
    for _, c in ipairs(clues) do
        local mode = (c.mode == "x" or c.mode == "v") and "x" or "n"
        table.insert(_clues_by_mode[mode], c)
    end
end

function M.enable()
    assert(M.config, "keystone.clue: config not set")
    _build()

    _ns = _ns or vim.api.nvim_create_namespace("keystone_clue")
    vim.on_key(_on_key, _ns)

    _augroup = vim.api.nvim_create_augroup("keystone_clue", { clear = true })
    vim.api.nvim_create_autocmd("ModeChanged", {
        group = _augroup,
        callback = function()
            if _active then
                _reset()
            end
        end,
    })
end

function M.disable()
    if _ns then
        vim.on_key(nil, _ns)
    end
    if _augroup then
        pcall(vim.api.nvim_del_augroup_by_id, _augroup)
        _augroup = nil
    end
    _reset()
end

-- ---------------------------------------------------------------------------
-- Test seam: the real `typed` argument is only ever populated by genuine TTY
-- input, so the state machine cannot be exercised through `feedkeys`/`nvim_input`
-- (they report `typed == ""`). These expose the handler and a state snapshot so
-- the begin / extend / reset transitions can be unit-tested. Build the trigger
-- lookups with `_build()` after setting `M.config`.
-- ---------------------------------------------------------------------------
M._build = _build
M._handle_key = _handle_key
M._reset = _reset

---@return { active: boolean, raw: string, mode: string?, win: boolean }
function M._state()
    return {
        active = _active,
        raw = _raw,
        mode = _mode,
        win = _handle ~= nil and vim.api.nvim_win_is_valid(_handle.win) or false,
    }
end

return M
