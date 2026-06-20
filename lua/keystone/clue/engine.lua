--- Active keymap-hint engine, in the style of which-key / mini.clue.
---
--- Each configured trigger key (e.g. `<leader>`, `g`, `<C-w>`) is mapped with
--- `nowait` so pressing it hands control here immediately. We then read the
--- following keys ourselves with `vim.fn.getcharstr()` — which blocks for as
--- long as needed, so a sequence resolves whether it is typed quickly or slowly
--- — while showing a floating window of the keys that may come next.
---
--- We never execute the resolved command ourselves. Once a sequence is complete
--- we *re-feed* it to Neovim with `nvim_feedkeys(..., "mit")`, so the real
--- mapping (or built-in) runs natively with counts, registers, operators and
--- dot-repeat all intact. To stop the re-fed trigger key from recursing back
--- into us, every trigger is unmapped for the duration of the feed and re-mapped
--- on the next tick (plus an `_executing` guard for the rare timing race).
---
--- Window operations can't run inside the libuv timer that fires while
--- `getcharstr()` blocks (that is a "fast" context), so the show is bounced
--- through `vim.schedule()`; a monotonically increasing token drops shows that a
--- newer keystroke or teardown has superseded.
local keys = require("keystone.clue.keys")
local window = require("keystone.clue.window")

local M = {}

--- Shared config table, set by `keystone.clue` (via `enable`).
---@type keystone.clue.Config?
M.config = nil

-- special keys, in raw byte form
local _ESC = "\27"
local _CTRL_C = "\3"
local _CR = "\r"
local _NL = "\n"
local _BS = vim.api.nvim_replace_termcodes("<BS>", true, true, true)

-- built from config on enable
local _triggers = {} ---@type { mode: string, raw: string }[]
local _clues = { n = {}, x = {} } ---@type table<string, keystone.clue.Clue[]>

-- only one query runs at a time, since `getcharstr` blocks
local _win = nil ---@type keystone.clue.WinHandle?
local _timer = nil ---@type uv.uv_timer_t?
local _token = 0 -- supersedes / invalidates pending scheduled shows
local _executing = false -- re-entry guard during the re-feed

-- forward declarations (assigned below; referenced as upvalues)
local _run, _exec, _show, _schedule_show, _close_window
local _map, _unmap, _map_all, _unmap_all

--- The keymap left-hand side for a trigger's raw bytes (e.g. `" "` -> `<Space>`,
--- `"\23"` -> `<C-W>`), as accepted by `vim.keymap.set`.
---@param raw string
---@return string
local function _lhs(raw)
    return vim.fn.keytrans(raw)
end

function _map(mode, raw)
    vim.keymap.set(mode, _lhs(raw), function()
        _run(mode, raw)
    end, { nowait = true, silent = true, desc = "keystone.clue trigger" })
end

function _unmap(mode, raw)
    pcall(vim.keymap.del, mode, _lhs(raw))
end

function _map_all()
    for _, t in ipairs(_triggers) do
        _map(t.mode, t.raw)
    end
end

function _unmap_all()
    for _, t in ipairs(_triggers) do
        _unmap(t.mode, t.raw)
    end
end

function _close_window()
    _token = _token + 1 -- invalidate any pending scheduled show
    if _timer then
        _timer:stop()
    end
    if _win then
        window.close(_win)
        _win = nil
    end
end

---@param qraw string accumulated raw query (trigger + following keys)
---@param maps keystone.clue.Map[]
function _show(qraw, maps)
    local entries = keys.clues(maps, qraw, M.config._groups)
    if #entries == 0 then
        return _close_window()
    end
    local title = " " .. vim.fn.keytrans(qraw) .. " "
    if _win and vim.api.nvim_win_is_valid(_win.win) then
        window.update(_win, entries, title, M.config.win)
    else
        _win = window.open(entries, title, M.config.win)
    end
    pcall(vim.cmd, "redraw")
end

--- Show after `win.delay` (debounced), or immediately if already shown. The
--- timer fires inside `getcharstr`'s blocking wait, so the actual window work is
--- bounced out of the fast context via `vim.schedule`.
---@param qraw string
---@param maps keystone.clue.Map[]
function _schedule_show(qraw, maps)
    _token = _token + 1
    local tok = _token
    _timer = _timer or vim.uv.new_timer()
    assert(_timer)
    _timer:stop()
    local shown = _win ~= nil and vim.api.nvim_win_is_valid(_win.win)
    local delay = shown and 0 or (M.config.win.delay or 0)
    _timer:start(delay, 0, function()
        vim.schedule(function()
            if tok == _token then
                _show(qraw, maps)
            end
        end)
    end)
end

--- The register Neovim uses when none is given (depends on `'clipboard'`).
---@return string
local function _default_register()
    local cb = vim.o.clipboard or ""
    if cb:find("unnamedplus") then
        return "+"
    end
    if cb:find("unnamed") then
        return "*"
    end
    return '"'
end

--- Re-feed the resolved sequence so Neovim runs it natively.
---@param query_raw string
function _exec(query_raw)
    _close_window()

    local feed = query_raw
    if vim.v.count > 0 then
        feed = tostring(vim.v.count) .. feed
    end
    local reg = vim.v.register
    if reg ~= "" and reg ~= _default_register() then
        local expr = reg == "=" and (vim.fn.getreginfo("=").regcontents[1] .. "\r") or ""
        feed = '"' .. reg .. expr .. feed
    end

    -- Unmap every trigger so the re-fed keys (which may contain a trigger key)
    -- resolve against user / built-in mappings instead of recursing into us.
    _executing = true
    _unmap_all()
    vim.api.nvim_feedkeys(feed, "mit", false)
    vim.schedule(function()
        _map_all()
        vim.schedule(function()
            _executing = false
        end)
    end)
end

--- Drive one trigger interaction: read keys, narrow, then re-feed.
---@param mode string "n" | "x"
---@param trigger_raw string raw bytes of the trigger key
function _run(mode, trigger_raw)
    if _executing then
        return -- a re-fed trigger slipped through before remap; let it pass
    end

    local maps = keys.collect(mode, _clues[mode])
    local query = { trigger_raw } ---@type string[]
    local function qraw()
        return table.concat(query)
    end

    if not keys.has_children(maps, trigger_raw) then
        return _exec(trigger_raw) -- nothing follows; run the trigger as-is
    end

    _schedule_show(qraw(), maps)

    while true do
        local ok, ch = pcall(vim.fn.getcharstr)
        if not ok or ch == nil or ch == "" or ch == _ESC or ch == _CTRL_C then
            return _close_window() -- cancelled
        end

        if ch == _CR or ch == _NL then
            return _exec(qraw()) -- accept the current prefix
        end

        if ch == _BS then
            table.remove(query)
            if #query == 0 then
                return _close_window()
            end
            _schedule_show(qraw(), maps)
        else
            table.insert(query, ch)
            if keys.has_children(maps, qraw()) then
                _schedule_show(qraw(), maps) -- more keys may follow
            else
                return _exec(qraw()) -- unique target, or no continuation
            end
        end
    end
end

--- Rebuild trigger and per-mode virtual clue lists from `M.config`.
local function _build()
    _triggers = {}
    _clues = { n = {}, x = {} }

    for _, t in ipairs(M.config.triggers or {}) do
        local mode = (t.mode == "x" or t.mode == "v") and "x" or "n"
        local raw = keys.to_raw(t.keys)
        if raw ~= "" then
            table.insert(_triggers, { mode = mode, raw = raw })
        end
    end

    local clues = {} ---@type keystone.clue.Clue[]
    if M.config.builtin_clues then
        vim.list_extend(clues, require("keystone.clue.builtin"))
    end
    vim.list_extend(clues, M.config.clues or {})
    for _, c in ipairs(clues) do
        local mode = (c.mode == "x" or c.mode == "v") and "x" or "n"
        table.insert(_clues[mode], c)
    end
end

--- Start the engine. `config` becomes active (defaults to `M.config`).
---@param config keystone.clue.Config?
function M.enable(config)
    M.config = config or M.config
    assert(M.config, "keystone.clue: config not set")
    _build()
    _map_all()
end

function M.disable()
    _close_window()
    _unmap_all()
end

--- Rebuild the trigger and virtual-clue lookups from the current `M.config`,
--- e.g. after `keystone.clue.add` mutates `config.clues`. Group labels are read
--- live at show-time and need no rebuild.
function M.refresh()
    if M.config then
        _build()
    end
end

-- ---------------------------------------------------------------------------
-- Test seam. The `getcharstr` loop can't be driven synchronously (it blocks on
-- real input), so it is covered by an integration test that runs a child
-- Neovim. This exposes the pure per-key decision so the branching can be
-- unit-tested directly; build lookups with `_build()` after setting `M.config`.
-- ---------------------------------------------------------------------------
M._build = _build

--- What the query loop does for one key. Pure.
---@param maps keystone.clue.Map[]
---@param query_raw string current accumulated raw query
---@param ch string raw bytes of the pressed key
---@return "exec"|"continue"|"cancel"|"pop"
function M._decide(maps, query_raw, ch)
    if ch == "" or ch == _ESC or ch == _CTRL_C then
        return "cancel"
    end
    if ch == _CR or ch == _NL then
        return "exec"
    end
    if ch == _BS then
        return "pop"
    end
    if keys.has_children(maps, query_raw .. ch) then
        return "continue"
    end
    return "exec"
end

return M
