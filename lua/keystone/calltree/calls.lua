local M = {}

--- A node of the call hierarchy as we keep it internally, normalized from a
--- `CallHierarchyItem` plus (for a call, rather than the root) the ranges of the
--- call sites that produced it.
---@class keystone.calltree.Call
---@field name string
---@field detail string?
---@field kind integer LSP `SymbolKind`
---@field uri string document containing the *symbol*
---@field lnum integer 1-based line of the symbol's selection start
---@field col integer 0-based column of the symbol's selection start
---@field end_lnum integer 1-based last line covered by the symbol
---@field call_uri string? document containing the call site, nil for the root
---@field call_lnum integer? 1-based line of the first call site
---@field call_col integer? 0-based column of the first call site
---@field call_count integer number of call sites (0 for the root)
---@field client_id integer id of the client that owns `item`
---@field item table raw `CallHierarchyItem`, needed for follow-up requests

---@alias keystone.calltree.Direction "incoming"|"outgoing"

--- Normalize a `CallHierarchyItem`. Returns nil for entries missing the range
--- we need to place them.
---@param item table
---@param client_id integer
---@return keystone.calltree.Call?
function M.normalize_item(item, client_id)
    if type(item) ~= "table" then return nil end
    if type(item.uri) ~= "string" then return nil end

    -- `range` spans the whole construct; `selectionRange` points at the name
    -- itself, which is where we want the cursor to land.
    local full_range = item.range
    local start_range = item.selectionRange or full_range
    if not full_range or not full_range["end"] then return nil end
    if not start_range or not start_range.start then return nil end

    return {
        name       = item.name or "?",
        detail     = item.detail,
        kind       = item.kind or 0,
        uri        = item.uri,
        lnum       = start_range.start.line + 1,
        col        = start_range.start.character,
        end_lnum   = full_range["end"].line + 1,
        call_count = 0,
        client_id  = client_id,
        item       = item,
    }
end

--- Earliest range in `ranges`, so a caller listed once for several call sites
--- jumps to the first of them.
---@param ranges table[]?
---@return table? range
local function _first_range(ranges)
    local first = nil
    for _, range in ipairs(ranges or {}) do
        local start = range and range.start
        if start then
            if not first
                or start.line < first.start.line
                or (start.line == first.start.line and start.character < first.start.character)
            then
                first = range
            end
        end
    end
    return first
end

---@param a keystone.calltree.Call
---@param b keystone.calltree.Call
---@return boolean
local function _by_position(a, b)
    if a.uri ~= b.uri then return a.uri < b.uri end
    if a.lnum ~= b.lnum then return a.lnum < b.lnum end
    if a.col ~= b.col then return a.col < b.col end
    return a.name < b.name
end

--- Normalize a `callHierarchy/incomingCalls` or `callHierarchy/outgoingCalls`
--- reply into a position-sorted list.
---
--- The two replies differ in where the call sites live: for incoming calls
--- `fromRanges` are positions inside the *caller* (`from`), for outgoing calls
--- they are positions inside the item we asked about, hence `parent_uri`.
---@param result table[]? raw reply
---@param direction keystone.calltree.Direction
---@param parent_uri string uri of the item the request was made for
---@param client_id integer
---@return keystone.calltree.Call[]
function M.normalize_calls(result, direction, parent_uri, client_id)
    local calls = {}
    for _, entry in ipairs(result or {}) do
        local target = type(entry) == "table" and (direction == "incoming" and entry.from or entry.to)
        local call = target and M.normalize_item(target, client_id)
        if call then
            local ranges = type(entry.fromRanges) == "table" and entry.fromRanges or {}
            local first = _first_range(ranges)
            if first then
                call.call_uri  = direction == "incoming" and call.uri or parent_uri
                call.call_lnum = first.start.line + 1
                call.call_col  = first.start.character
            end
            call.call_count = #ranges
            calls[#calls + 1] = call
        end
    end
    table.sort(calls, _by_position)
    return calls
end

--- Key identifying the symbol a call points at, used to spot recursion: a node
--- whose key already appears among its ancestors would expand forever.
---@param call keystone.calltree.Call
---@return string
function M.identity(call)
    return call.uri .. ":" .. call.lnum .. ":" .. call.col .. ":" .. call.name
end

-- ---------------------------------------------------------------------------
-- Provider: resolves the symbol under the cursor to a call hierarchy root and
-- fetches a node's calls over LSP. Hides the request/reply plumbing from
-- CallTree: client lookup, position encoding and request-counter staleness live
-- here.
-- ---------------------------------------------------------------------------

local _METHOD_PREPARE  = "textDocument/prepareCallHierarchy"
local _METHOD_INCOMING = "callHierarchy/incomingCalls"
local _METHOD_OUTGOING = "callHierarchy/outgoingCalls"

---@class keystone.calltree.calls.Provider.PrepareHandlers
---@field on_root fun(root: keystone.calltree.Call) resolved the symbol under the cursor
---@field on_unavailable fun(reason: string) nothing to show; `reason` is a human-readable placeholder

---@class keystone.calltree.calls.Provider.CallsHandlers
---@field on_calls fun(calls: keystone.calltree.Call[]) reply received, possibly empty
---@field on_unavailable fun(reason: string) the request could not be made or failed

---@class keystone.calltree.calls.Provider
---@field new fun(self:keystone.calltree.calls.Provider):keystone.calltree.calls.Provider
---@field private _prepare_counter integer
local Provider = {}
Provider.__index = Provider

function Provider:new(...)
    local obj = setmetatable({}, self)
    if obj.init then obj:init(...) end
    return obj
end

function Provider:init()
    self._prepare_counter = 0
end

--- Resolves the symbol at the cursor of `winid` to a call hierarchy root.
--- Exactly one handler fires, and never for a reply overtaken by a later
--- `prepare` on this provider.
---@param bufnr integer
---@param winid integer window whose cursor names the symbol
---@param handlers keystone.calltree.calls.Provider.PrepareHandlers
function Provider:prepare(bufnr, winid, handlers)
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_win_is_valid(winid) then
        handlers.on_unavailable("No buffer")
        return
    end

    local client = vim.lsp.get_clients({ bufnr = bufnr, method = _METHOD_PREPARE })[1]
    if not client then
        handlers.on_unavailable("No call hierarchy support")
        return
    end

    self._prepare_counter = self._prepare_counter + 1
    local request_id = self._prepare_counter

    local params = vim.lsp.util.make_position_params(winid, client.offset_encoding)
    client:request(_METHOD_PREPARE, params, function(err, result)
        -- Drop replies overtaken by a newer request.
        if request_id ~= self._prepare_counter then return end

        -- A null result can arrive as vim.NIL, so check the type.
        if err or type(result) ~= "table" or #result == 0 then
            handlers.on_unavailable(err and "Call hierarchy request failed" or "No symbol under cursor")
            return
        end

        local root = M.normalize_item(result[1], client.id)
        if not root then
            handlers.on_unavailable("No symbol under cursor")
            return
        end
        handlers.on_root(root)
    end, bufnr)
end

--- Fetches the calls into (or out of) `call`. The follow-up request must go to
--- the client that produced the item, since `CallHierarchyItem.data` is opaque
--- and server-specific.
---@param call keystone.calltree.Call
---@param direction keystone.calltree.Direction
---@param handlers keystone.calltree.calls.Provider.CallsHandlers
function Provider:calls(call, direction, handlers)
    local client = vim.lsp.get_client_by_id(call.client_id)
    if not client or client:is_stopped() then
        handlers.on_unavailable("LSP client gone")
        return
    end

    local method = direction == "incoming" and _METHOD_INCOMING or _METHOD_OUTGOING
    if not client:supports_method(method) then
        handlers.on_unavailable("No " .. direction .. " calls support")
        return
    end

    client:request(method, { item = call.item }, function(err, result)
        if err then
            handlers.on_unavailable("Call request failed")
            return
        end
        handlers.on_calls(M.normalize_calls(
            type(result) == "table" and result or nil, direction, call.uri, client.id))
    end)
end

M.Provider = Provider

return M
