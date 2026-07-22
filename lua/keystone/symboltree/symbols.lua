local M = {}

--- A symbol as we keep it internally, normalized from either the hierarchical
--- `DocumentSymbol[]` or the flat `SymbolInformation[]` server reply.
---@class keystone.symboltree.Symbol
---@field name string
---@field detail string?
---@field kind integer
---@field lnum integer 1-based line of the symbol's selection start
---@field col integer 0-based column of the symbol's selection start
---@field end_lnum integer 1-based last line covered by the symbol
---@field children keystone.symboltree.Symbol[]

--- Normalize one server symbol. Returns nil for entries missing the range we
--- need to place them.
---@param sym table
---@return keystone.symboltree.Symbol?
local function _normalize(sym)
    if type(sym) ~= "table" then return nil end

    -- DocumentSymbol carries `range`/`selectionRange` directly; SymbolInformation
    -- nests a single range under `location`. `selectionRange` points at the name
    -- itself, which is where we want the cursor to land; `range` spans the whole
    -- construct, which is what decides enclosure.
    local location_range = sym.location and sym.location.range
    local full_range = sym.range or location_range
    local start_range = sym.selectionRange or full_range
    if not full_range or not start_range then return nil end
    if not full_range["end"] or not start_range.start then return nil end

    local children = {}
    for _, child in ipairs(sym.children or {}) do
        local normalized = _normalize(child)
        if normalized then children[#children + 1] = normalized end
    end

    return {
        name     = sym.name or "?",
        detail   = sym.detail,
        kind     = sym.kind or 0,
        lnum     = start_range.start.line + 1,
        col      = start_range.start.character,
        end_lnum = full_range["end"].line + 1,
        children = children,
    }
end

---@param a keystone.symboltree.Symbol
---@param b keystone.symboltree.Symbol
---@return boolean
local function _by_position(a, b)
    if a.lnum ~= b.lnum then return a.lnum < b.lnum end
    if a.col ~= b.col then return a.col < b.col end
    return a.name < b.name
end

---@param symbols keystone.symboltree.Symbol[]
local function _sort_recursive(symbols)
    table.sort(symbols, _by_position)
    for _, symbol in ipairs(symbols) do
        _sort_recursive(symbol.children)
    end
end

--- Normalize a `textDocument/documentSymbol` reply into a position-sorted tree.
--- Accepts both reply shapes; a flat `SymbolInformation[]` yields a flat list.
---@param result table[]?
---@return keystone.symboltree.Symbol[]
function M.normalize(result)
    local symbols = {}
    for _, sym in ipairs(result or {}) do
        local normalized = _normalize(sym)
        if normalized then symbols[#symbols + 1] = normalized end
    end
    _sort_recursive(symbols)
    return symbols
end

--- Depth-first path to the innermost symbol whose range covers `line`.
---@param symbols keystone.symboltree.Symbol[]
---@param line integer 1-based
---@return keystone.symboltree.Symbol[] path outermost first, empty if none match
function M.path_at_line(symbols, line)
    local path = {}
    local current = symbols
    while current do
        local match = nil
        for _, symbol in ipairs(current) do
            if line >= symbol.lnum and line <= symbol.end_lnum then
                match = symbol
                break
            end
        end
        if not match then break end
        path[#path + 1] = match
        current = match.children
    end
    return path
end

-- ---------------------------------------------------------------------------
-- Provider: fetches document symbols for a buffer over LSP and normalizes the
-- reply with `M.normalize` above. Hides the request/reply plumbing from
-- SymbolTree: client lookup and request-counter staleness live here.
-- ---------------------------------------------------------------------------

---@param bufnr integer
---@return vim.lsp.Client?
local function _symbol_client(bufnr)
    local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/documentSymbol" })
    return clients[1]
end

---@class keystone.symboltree.symbols.Provider.Handlers
---@field on_symbols fun(symbols: keystone.symboltree.Symbol[]) received a non-empty symbol list
---@field on_unavailable fun(reason: string) no symbols to show; `reason` is a human-readable placeholder

---@class keystone.symboltree.symbols.Provider
---@field new fun(self:keystone.symboltree.symbols.Provider):keystone.symboltree.symbols.Provider
---@field private _request_counter integer
local Provider = {}
Provider.__index = Provider

function Provider:new(...)
    local obj = setmetatable({}, self)
    if obj.init then obj:init(...) end
    return obj
end

function Provider:init()
    self._request_counter = 0
end

--- Requests document symbols for `bufnr`. Exactly one handler fires, and never
--- for a reply that has been overtaken by a later `request` on this provider.
---@param bufnr integer
---@param handlers keystone.symboltree.symbols.Provider.Handlers
function Provider:request(bufnr, handlers)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        handlers.on_unavailable("No buffer")
        return
    end

    local client = _symbol_client(bufnr)
    if not client then
        handlers.on_unavailable("No LSP symbols")
        return
    end

    self._request_counter = self._request_counter + 1
    local request_id = self._request_counter

    local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
    client:request("textDocument/documentSymbol", params, function(err, result)
        -- Drop replies overtaken by a newer request.
        if request_id ~= self._request_counter then return end

        -- A null result can arrive as vim.NIL, so check the type.
        if err or type(result) ~= "table" or #result == 0 then
            handlers.on_unavailable(err and "Symbol request failed" or "No symbols")
            return
        end

        handlers.on_symbols(M.normalize(result))
    end, bufnr)
end

M.Provider = Provider

return M
