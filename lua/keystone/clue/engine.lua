--- The clue engine. Each configured trigger is a `nowait` keymap that, when
--- pressed, runs a synchronous loop: read the next key with `getcharstr`, descend
--- the tree (showing the popup after a delay), and once a leaf or unknown key is
--- reached, re-feed the resolved sequence so the real mapping / builtin runs
--- natively (preserving counts, registers, operators and dot-repeat).
---
--- Triggers are registered both globally and, on `BufEnter`/`LspAttach`, as
--- buffer-local `nowait` shadows. The buffer-local copy is essential: `nowait`
--- on a *global* mapping does not stop Neovim from waiting out `timeoutlen` when
--- a buffer-local mapping shares the trigger as a prefix (e.g. LSP's `gd`/`gr`).
--- A buffer-local `nowait` full match suppresses that wait, so the popup fires
--- immediately instead of stalling in operator-pending.
local Keys = require("keystone.clue.keys")
local Tree = require("keystone.clue.tree")

local uv = vim.uv or vim.loop

local M = {}

---@type { mode: string, lhs: string }[]
M._registered = {}
---@type table<integer, { mode: string, lhs: string }[]>
M._buf_registered = {}
---@type keystone.clue.Trigger[]
M._triggers = {}
M._active = false
M._augroup = nil

--- Resolve the live mode to a mapmode letter (n/x/o/i/c/...).
---@return string
local function _mapmode()
    local mode = vim.api.nvim_get_mode().mode
    mode = mode:gsub(Keys.t("<C-V>"), "v"):gsub(Keys.t("<C-S>"), "s"):lower()
    if mode:sub(1, 2) == "no" then
        return "o"
    end
    if mode:sub(1, 1) == "v" then
        return "x"
    end
    -- Replace / virtual-replace modes use insert-mode mappings.
    if mode:sub(1, 1) == "r" then
        return "i"
    end
    return mode:sub(1, 1):match("[ncitsxo]") or "n"
end
M.mapmode = _mapmode

--- The register that an unprefixed action would use, so we only inject an
--- explicit register when the user actually chose a different one.
---@return string
local function _default_reg()
    if vim.g.loaded_clipboard_provider ~= 2 then
        return '"'
    end
    local cb = vim.o.clipboard
    if cb:find("unnamedplus") then
        return "+"
    end
    if cb:find("unnamed") then
        return "*"
    end
    return '"'
end

--- Is `lhs` already bound to a real (non-trigger) mapping in `mode`?
---@param mode string
---@param lhs string
---@return boolean
local function _already_mapped(mode, lhs)
    local m = vim.fn.maparg(lhs, mode, false, true)
    if not m or vim.tbl_isempty(m) then
        return false
    end
    if m.desc and m.desc:find("keystone-clue-trigger", 1, true) then
        return false
    end
    local rhs = m.rhs
    if type(rhs) == "string" and (rhs == "" or rhs:lower() == "<nop>") then
        return false
    end
    return true
end

--- (Re)register the global trigger keymaps from `M._triggers`.
local function _register_globals()
    for _, r in ipairs(M._registered) do
        pcall(vim.keymap.del, r.mode, r.lhs)
    end
    M._registered = {}
    for _, trig in ipairs(M._triggers) do
        local mode, lhs = trig.mode, trig.keys
        if not _already_mapped(mode, lhs) then
            local norm = Keys.norm(lhs)
            local ok = pcall(vim.keymap.set, mode, lhs, function()
                M.start(norm)
            end, { nowait = true, silent = true, desc = "keystone-clue-trigger" })
            if ok then
                M._registered[#M._registered + 1] = { mode = mode, lhs = lhs }
            end
        end
    end
end

--- Set buffer-local `nowait` trigger shadows for `bufnr`. These take precedence
--- over the global triggers and, unlike them, fire immediately even when a
--- buffer-local mapping shares the prefix (the operator-pending delay fix).
---@param bufnr integer
local function _apply_buf_triggers(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    local list = {} ---@type { mode: string, lhs: string }[]
    for _, trig in ipairs(M._triggers) do
        local mode, lhs = trig.mode, trig.keys
        -- `_already_mapped` inspects the current buffer, so resolve it there.
        local mapped = vim.api.nvim_buf_call(bufnr, function()
            return _already_mapped(mode, lhs)
        end)
        if not mapped then
            local norm = Keys.norm(lhs)
            local ok = pcall(vim.keymap.set, mode, lhs, function()
                M.start(norm)
            end, { buffer = bufnr, nowait = true, silent = true, desc = "keystone-clue-trigger" })
            if ok then
                list[#list + 1] = { mode = mode, lhs = lhs }
            end
        end
    end
    M._buf_registered[bufnr] = list
end

---@param bufnr integer
local function _remove_buf_triggers(bufnr)
    local list = M._buf_registered[bufnr]
    if not list then
        return
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
        for _, r in ipairs(list) do
            pcall(vim.keymap.del, r.mode, r.lhs, { buffer = bufnr })
        end
    end
    M._buf_registered[bufnr] = nil
end

---@param triggers keystone.clue.Trigger[]
function M.register_triggers(triggers)
    M._triggers = triggers
    _register_globals()

    M._augroup = vim.api.nvim_create_augroup("keystone.clue.engine", { clear = true })
    vim.api.nvim_create_autocmd({ "BufEnter", "LspAttach" }, {
        group = M._augroup,
        desc = "keystone-clue buffer-local triggers",
        callback = function(ev)
            _apply_buf_triggers(ev.buf)
        end,
    })
    -- Drop tracking when a buffer goes away. `BufDelete` covers `:bdelete`
    -- (which unlists without wiping), so the table does not grow unbounded.
    vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
        group = M._augroup,
        callback = function(ev)
            M._buf_registered[ev.buf] = nil
        end,
    })
    _apply_buf_triggers(vim.api.nvim_get_current_buf())
end

--- Temporarily remove the triggers, then restore them on the next tick. This
--- prevents the about-to-be-fed key sequence from re-entering the engine: the
--- fed typeahead is drained (running the real mapping) before the restore runs.
--- Both the global triggers and the current buffer's shadows are dropped, since
--- either could otherwise catch the re-fed prefix.
local function _suspend()
    local bufnr = vim.api.nvim_get_current_buf()
    local saved = M._registered
    M._registered = {}
    for _, r in ipairs(saved) do
        pcall(vim.keymap.del, r.mode, r.lhs)
    end
    local had_buf = M._buf_registered[bufnr] ~= nil
    _remove_buf_triggers(bufnr)
    vim.schedule(function()
        if #M._registered == 0 then
            _register_globals()
        end
        if had_buf then
            _apply_buf_triggers(bufnr)
        end
    end)
end

--- Re-feed a resolved key sequence so Neovim runs it natively.
---@param mode string
---@param keystr string normalised key sequence
local function _execute(mode, keystr)
    if mode ~= "x" and mode ~= "o" and mode ~= "i" and mode ~= "c" then
        if vim.v.count > 0 then
            keystr = vim.v.count .. keystr
        end
        local reg = vim.v.register
        if reg and reg ~= "" and reg ~= _default_reg() then
            keystr = '"' .. reg .. keystr
        end
    end
    _suspend()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keystr, true, true, true), "mit", false)
end

--- The interactive loop. Runs synchronously inside the trigger keymap.
---@param mode string
---@param start keystone.clue.Node  the node the trigger resolved to; `<BS>` never ascends above it
---@param node keystone.clue.Node
local function _loop(mode, start, node)
    local View = require("keystone.clue.view")
    local delay = require("keystone.clue").config.delay

    while true do
        local kids = Tree.children(node)
        if #kids == 0 then
            _execute(mode, node.keys)
            return
        end

        local by_key = {} ---@type table<string, keystone.clue.Node>
        for _, c in ipairs(kids) do
            by_key[c.key] = c
        end

        -- Show the popup after `delay` ms (immediately if already visible). The
        -- timer fires while we block in getcharstr because that pumps the loop.
        -- Skip it entirely while a macro is replaying (the resolve loop still runs,
        -- reading from the macro typeahead, but no popup flickers mid-replay) and
        -- in cmdline mode, where opening a float over the command line is unsafe.
        local current = node
        local timer
        if vim.fn.reg_executing() == "" and mode ~= "c" then
            timer = uv.new_timer()
            if timer then
                timer:start(
                    View.visible() and 0 or delay,
                    0,
                    vim.schedule_wrap(function()
                        if M._active then
                            View.show(current)
                        end
                    end)
                )
            end
        end
        local ok, char = pcall(vim.fn.getcharstr)
        if timer then
            timer:stop()
            pcall(function()
                timer:close()
            end)
        end

        if not ok then
            return
        end
        local key = vim.fn.keytrans(char)

        if key == "" or key == "<Esc>" or key == "<C-C>" then
            return
        elseif key == "<BS>" then
            -- Ascend, but never past the node the trigger resolved to.
            node = (node ~= start and node.parent) or start
        elseif key:find("Mouse") or key:find("Scroll") then
            -- ignore mouse / scroll-wheel events
        else
            local child = by_key[key]
            if child and Tree.has_children(child) then
                node = child
            elseif child then
                _execute(mode, child.keys)
                return
            else
                _execute(mode, node.keys .. key)
                return
            end
        end
    end
end

--- Entry point invoked by a trigger keymap.
---@param prefix string normalised trigger sequence
function M.start(prefix)
    if M._active then
        return
    end
    local mode = _mapmode()
    local clue = require("keystone.clue")
    local root = Tree.build(mode, clue.get_clues(mode), clue.get_builtins(mode))
    local node = Tree.find(root, prefix)

    if not node or not Tree.has_children(node) then
        _execute(mode, prefix)
        return
    end

    local View = require("keystone.clue.view")
    M._active = true
    local ok, err = pcall(_loop, mode, node, node)
    M._active = false
    View.hide()
    if not ok then
        vim.schedule(function()
            vim.notify("[keystone.clue] " .. tostring(err), vim.log.levels.ERROR)
        end)
    end
end

return M
