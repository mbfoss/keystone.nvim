--- State machine driving a single clue interaction.
---
--- When a trigger fires, `run` reads keypresses one at a time with
--- `getcharstr`, narrowing the set of matching maps. The clue window is shown
--- after `delay` ms of waiting (the timer fires while `getcharstr` blocks). The
--- interaction ends when the sequence resolves to a map (executed directly), no
--- longer matches anything (replayed natively), or is cancelled with `<Esc>`.
local keys = require("keystone.clue.keys")
local window = require("keystone.clue.window")

local M = {}

--- Shared config table, set by `keystone.clue` on enable.
---@type table?
M.config = nil

local _active = false

--- Execute a resolved map directly, never re-feeding the typed keys (so the
--- trigger keymap can't re-fire). `<Cmd>`/`<Plug>` right-hand sides are fed with
--- remap; everything else honours the map's `noremap`.
---@param map keystone.clue.Map
local function _execute(map)
    if map.callback then
        local ok, ret = pcall(map.callback)
        if ok and map.expr == 1 and type(ret) == "string" and ret ~= "" then
            local feed = vim.api.nvim_replace_termcodes(ret, true, true, true)
            vim.api.nvim_feedkeys(feed, map.noremap == 1 and "n" or "m", false)
        end
        return
    end
    local rhs = map.rhs
    if not rhs or rhs == "" then
        return
    end
    if map.expr == 1 then
        local ok, ret = pcall(vim.api.nvim_eval, rhs)
        if not (ok and type(ret) == "string") then
            return
        end
        rhs = ret
    end
    local feed = vim.api.nvim_replace_termcodes(rhs, true, true, true)
    vim.api.nvim_feedkeys(feed, map.noremap == 1 and "n" or "m", false)
end

--- Replay raw bytes with no remapping (so the trigger keymap is bypassed and
--- built-in behaviour like `gg`, `]p`, `<C-w>v` runs as typed).
---@param raw string
---@param count string
local function _native(raw, count)
    vim.api.nvim_feedkeys(count .. raw, "n", false)
end

--- A large millisecond value standing in for "wait indefinitely".
local _FOREVER = 2 ^ 31

--- Wait up to `timeout_ms` for a keypress, polling the input queue so the event
--- loop keeps running (timers fire, the clue window redraws). Returns the raw
--- key, or `nil` if the timeout elapsed without one. `getcharstr(0)` consumes a
--- key only when one is available, so this never blocks the loop.
---@param timeout_ms integer
---@return string?
local function _wait_char(timeout_ms)
    local key
    vim.wait(timeout_ms, function()
        local ok, ch = pcall(vim.fn.getcharstr, 0)
        if ok and ch ~= nil and ch ~= "" then
            key = ch
            return true
        end
        return false
    end, 5)
    return key
end

---@param mode string
---@param trigger_keys string
local function _loop(mode, trigger_keys)
    local config = assert(M.config, "keystone.clue: config not set")
    local count = vim.v.count ~= 0 and tostring(vim.v.count) or ""
    local trigger_raw = keys.to_raw(trigger_keys)
    local prefix = keys.tokenize(trigger_raw)
    local maps = keys.collect(mode)

    --- raw bytes typed after the trigger (one per appended token)
    local typed = {} ---@type string[]
    local function typed_raw()
        return trigger_raw .. table.concat(typed)
    end

    local handle ---@type keystone.clue.WinHandle?
    local shown = false

    local function title()
        return " " .. vim.fn.keytrans(typed_raw()) .. " "
    end

    local function render()
        local entries = keys.clues(maps, prefix, config._groups)
        if #entries == 0 then
            return
        end
        if handle and vim.api.nvim_win_is_valid(handle.win) then
            window.update(handle, entries, title(), config.win)
        else
            handle = window.open(entries, title(), config.win)
        end
        shown = true
        vim.cmd("redraw")
    end

    local function cleanup()
        window.close(handle)
        handle = nil
    end

    local timeoutlen = vim.o.timeoutlen

    while true do
        local exact = keys.exact_map(maps, prefix)

        if not keys.has_children(maps, prefix) then
            cleanup()
            if exact then
                _execute(exact)
            else
                _native(typed_raw(), count)
            end
            return
        end

        -- Keep the window in sync with the current prefix, then decide how long
        -- to wait for the next key:
        --   * not shown yet  -> wait `delay`, then pop the window
        --   * shown + exact   -> wait `timeoutlen`, then commit the exact map
        --   * shown otherwise -> wait indefinitely for the next key
        local timeout
        if shown then
            render()
            timeout = (exact and timeoutlen > 0) and timeoutlen or _FOREVER
        elseif (config.delay or 0) <= 0 then
            render()
            timeout = _FOREVER
        else
            timeout = config.delay
        end

        local ch = _wait_char(timeout)

        if ch == nil then
            if not shown then
                render()
            elseif exact then
                -- `timeoutlen` elapsed on an exact-but-extendable map (e.g. an
                -- operator like `gc` that is also a prefix of `gcc`): commit it.
                cleanup()
                _execute(exact)
                return
            else
                -- indefinite wait returned without a key: interrupted.
                cleanup()
                return
            end
        else
            local tok = keys.key_token(ch)
            if tok == "<Esc>" then
                cleanup()
                return
            end

            local next_prefix = vim.list_extend({}, prefix)
            table.insert(next_prefix, tok)

            if keys.count_prefix(maps, next_prefix) == 0 then
                -- the new key continues no tracked map
                cleanup()
                if exact then
                    -- the current prefix is itself a mapping (e.g. an operator
                    -- like `gc`): run it, then feed the breaking key as its
                    -- motion.
                    _execute(exact)
                    vim.api.nvim_feedkeys(ch, "n", false)
                else
                    _native(typed_raw() .. ch, count)
                end
                return
            end

            prefix = next_prefix
            table.insert(typed, ch)
        end
    end
end

--- Entry point invoked by a trigger keymap. Re-entrant calls are ignored.
---@param mode string
---@param trigger_keys string
function M.run(mode, trigger_keys)
    if _active then
        return
    end
    _active = true
    local ok, err = pcall(_loop, mode, trigger_keys)
    _active = false
    if not ok then
        vim.schedule(function()
            vim.notify("[keystone.clue] " .. tostring(err), vim.log.levels.ERROR)
        end)
    end
end

return M
