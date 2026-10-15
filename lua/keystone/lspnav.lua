-- ---------------------------------------------------------------------------
-- keystone.lspnav
--
-- Motions to the next and previous function or type of a buffer, read from the
-- server's own `textDocument/documentSymbol` tree, which Neovim's LSP defaults
-- have no equivalent of. Nested and local definitions are stops too, since the
-- tree is walked whole, and the server decides what counts as a function.
--
-- This module maps nothing and registers nothing: it exposes functions, and a
-- user who wants keys names one of them. Choosing the symbol a motion lands on
-- is done by the pure functions above the driver, which take a symbol tree and
-- a cursor position and need no client of their own.
-- ---------------------------------------------------------------------------

local M = {}

local symbols = require("keystone.util.lspsymbols")
local cfgutil = require("keystone.util.config")
local ui = require("keystone.util.ui")

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

---@class keystone.lspnav.Config
---@field function_kinds integer[]? LSP `SymbolKind` codes the function actions stop on
---@field type_kinds integer[]?     LSP `SymbolKind` codes the type actions stop on

---@type keystone.lspnav.Config
local _default_config = {
    function_kinds = { 6, 9, 12 },            -- Method, Constructor, Function
    type_kinds     = { 2, 3, 5, 10, 11, 23 }, -- Module, Namespace, Class, Enum, Interface, Struct
}

M.config = vim.deepcopy(_default_config)

local _setup = false

---@return keystone.lspnav.Config
function M.get_default_config()
    return vim.deepcopy(_default_config)
end

---@return boolean
function M.is_setup()
    return _setup
end

---@param opts? keystone.lspnav.Config
function M.setup(opts)
    _setup = true
    cfgutil.apply(M.config, _default_config, opts)
end

-- ---------------------------------------------------------------------------
-- Selection (pure)
-- ---------------------------------------------------------------------------

--- Which way a jump goes.
---@alias keystone.lspnav.Direction "next"|"prev"

--- A cursor position in LSP coordinates.
---@class keystone.lspnav.Pos
---@field line integer 1-based
---@field character integer offset in the client's `offset_encoding` units

---@type table<string, true>
local _ENCODINGS = { ["utf-8"] = true, ["utf-16"] = true, ["utf-32"] = true }

-- LSP defaults to utf-16, and so does this for a client that names something
-- else entirely.
---@param encoding string?
---@return "utf-8"|"utf-16"|"utf-32"
function M.encoding(encoding)
    if encoding and _ENCODINGS[encoding] then return encoding end
    return "utf-16"
end

--- Every symbol in the tree, depth-first, so a nested definition sits between
--- its parent and the definitions that follow it. Sorted by position, which
--- keeps `pick` independent of the order the tree arrived in.
---@param tree keystone.util.lspsymbols.Symbol[]
---@return keystone.util.lspsymbols.Symbol[]
function M.flatten(tree)
    local flat = {}
    local function walk(nodes)
        for _, node in ipairs(nodes) do
            flat[#flat + 1] = node
            walk(node.children)
        end
    end
    walk(tree)

    table.sort(flat, function(a, b)
        if a.lnum ~= b.lnum then return a.lnum < b.lnum end
        if a.col ~= b.col then return a.col < b.col end
        return a.name < b.name
    end)
    return flat
end

--- -1 when the symbol starts before `pos`, 1 when after, 0 at the same spot.
---@param sym keystone.util.lspsymbols.Symbol
---@param pos keystone.lspnav.Pos
---@return integer
local function _side(sym, pos)
    if sym.lnum ~= pos.line then return sym.lnum < pos.line and -1 or 1 end
    if sym.col ~= pos.character then return sym.col < pos.character and -1 or 1 end
    return 0
end

--- The symbol `count` stops away in `direction`, or nil at that end of the
--- buffer. Comparison is on line and column, not line alone, so two
--- declarations on one line stay distinct. A symbol the cursor already sits on
--- counts as neither direction, so a repeat press moves past it.
---@param flat keystone.util.lspsymbols.Symbol[] position-sorted, as `flatten` returns
---@param pos keystone.lspnav.Pos
---@param kinds integer[]? LSP `SymbolKind` codes to stop on; nil stops on nothing
---@param direction keystone.lspnav.Direction
---@param count? integer number of stops to move; defaults to 1
---@return keystone.util.lspsymbols.Symbol?
function M.pick(flat, pos, kinds, direction, count)
    local wanted = {}
    for _, kind in ipairs(kinds or {}) do
        wanted[kind] = true
    end

    local side = direction == "next" and 1 or -1
    local matches = {}
    for _, sym in ipairs(flat) do
        if wanted[sym.kind] and _side(sym, pos) == side then
            matches[#matches + 1] = sym
        end
    end
    if #matches == 0 then return nil end

    -- A count past the end stops at the end, like a Vim motion with an
    -- oversized count.
    count = math.max(count or 1, 1)
    local index = side == 1 and math.min(count, #matches) or math.max(#matches - count + 1, 1)
    return matches[index]
end

-- ---------------------------------------------------------------------------
-- Offsets (pure)
-- ---------------------------------------------------------------------------

--- A byte offset on one line as an LSP character offset.
---@param line string
---@param byte_col integer 0-based
---@param encoding "utf-8"|"utf-16"|"utf-32"
---@return integer
function M.char_offset(line, byte_col, encoding)
    byte_col = math.max(0, math.min(byte_col, #line))
    if encoding == "utf-8" then return byte_col end
    -- Errors on an index inside a character; the byte offset is close enough then.
    local ok, offset = pcall(vim.str_utfindex, line, encoding, byte_col)
    return ok and offset or byte_col
end

--- An LSP character offset as a byte offset on one line. An offset past the
--- end of the line lands on its last byte, which is where a cursor sat there
--- would be clamped to anyway.
---@param line string
---@param character integer 0-based
---@param encoding "utf-8"|"utf-16"|"utf-32"
---@return integer
function M.byte_col(line, character, encoding)
    character = math.max(character, 0)
    if encoding == "utf-8" then return math.min(character, #line) end
    local ok, byte_col = pcall(vim.str_byteindex, line, encoding, character)
    return ok and byte_col or #line
end

-- ---------------------------------------------------------------------------
-- Driver (requests symbols and moves the cursor)
-- ---------------------------------------------------------------------------

-- One provider for the module: it drops a reply that a later request has
-- overtaken, so a jump never lands on symbols read from an older buffer state.
local _provider = symbols.Provider:new()

--- The window `bufnr` sits in, showing it for the occasion when it is up
--- nowhere, with the cursor put at `line`/`col` when those are given.
---@param bufnr integer
---@param line? integer
---@param col? integer
---@return integer? winid nil when the buffer cannot be shown
local function _show(bufnr, line, col)
    -- pcall: showing a buffer can fail for reasons not visible from here, such
    -- as a modified buffer with 'nohidden'. A jump is not worth a traceback.
    local ok, win = pcall(ui.smart_open_buffer, bufnr, line, col)
    return ok and win or nil
end

--- Land on `target` in `bufnr`.
---@param bufnr integer
---@param target keystone.util.lspsymbols.Symbol
---@param encoding "utf-8"|"utf-16"|"utf-32"
local function _move(bufnr, target, encoding)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    -- The buffer can have been edited while the request was in flight, so the
    -- target symbol may sit past the end of the file it was read from.
    local lnum = math.min(target.lnum, vim.api.nvim_buf_line_count(bufnr))
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, true)[1] or ""
    _show(bufnr, lnum, M.byte_col(line, target.col, encoding))
end

--- Move the cursor to the next or previous symbol of the given kinds. A no-op
--- at the first or last match, and when no attached client serves
--- `textDocument/documentSymbol`: a motion at the edge of the buffer stays
--- quiet rather than reporting itself.
---@param direction keystone.lspnav.Direction
---@param kinds integer[]? LSP `SymbolKind` codes to stop on; nil stops on nothing
---@param bufnr? integer defaults to the current buffer
---@param count? integer number of stops to move; defaults to `vim.v.count1`
function M.jump(direction, kinds, bufnr, count)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    -- The window the jump works in. The cursor is read from there and moves
    -- within it, so a jump cannot read one window and land in another.
    local win = _show(bufnr)
    if not win then return end

    -- Read once, here: the reply arrives later, with the cursor moved on and
    -- `vim.v.count1` reset under the keymap.
    count = math.max(count or vim.v.count1, 1)
    local cursor = vim.api.nvim_win_get_cursor(win)
    local client = symbols.client(bufnr)
    local encoding = M.encoding(client and client.offset_encoding)
    local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], true)[1] or ""
    local pos = { line = cursor[1], character = M.char_offset(line, cursor[2], encoding) }

    _provider:request(bufnr, {
        on_symbols = function(tree)
            local target = M.pick(M.flatten(tree), pos, kinds, direction, count)
            if target then _move(bufnr, target, encoding) end
        end,
        on_unavailable = function() end,
    })
end

-- ---------------------------------------------------------------------------
-- Public actions
-- ---------------------------------------------------------------------------

---@param bufnr? integer
---@param count? integer
function M.next_function(bufnr, count)
    M.jump("next", M.config.function_kinds, bufnr, count)
end

---@param bufnr? integer
---@param count? integer
function M.prev_function(bufnr, count)
    M.jump("prev", M.config.function_kinds, bufnr, count)
end

---@param bufnr? integer
---@param count? integer
function M.next_type(bufnr, count)
    M.jump("next", M.config.type_kinds, bufnr, count)
end

---@param bufnr? integer
---@param count? integer
function M.prev_type(bufnr, count)
    M.jump("prev", M.config.type_kinds, bufnr, count)
end

return M
