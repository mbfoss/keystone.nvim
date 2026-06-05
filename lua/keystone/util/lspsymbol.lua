---@class keystone.util.SymbolInfo
---@field name string
---@field kind integer
---@field range? { start: { line: integer, character: integer }, end: { line: integer, character: integer } }
---@field children? keystone.util.SymbolInfo[]
---@field location? { range: { start: { line: integer, character: integer }, end: { line: integer, character: integer } } }

local Signal = require("keystone.util.Signal")
local throttle = require("keystone.util.throttle")

-- [bufnr] = DocumentSymbol[] | SymbolInformation[]
local _symbol_cache = {}

-- [bufnr] = debounced refresh fn
local _refresh_fns = {}

-- bufnrs with an attached documentSymbol-capable client
local _managed_bufs = {}

local _active = false
local _augroup_name = "keystone_lspsymbol"

-- Internal signal — emits (bufnr, chain) on symbol context changes.
local _signal = Signal.new()

local function _in_range(line0, range)
  return line0 >= range.start.line and line0 <= range["end"].line
end

local function _collect_enclosing(symbols, line0, chain)
  for _, sym in ipairs(symbols) do
    if sym.range and _in_range(line0, sym.range) then
      table.insert(chain, sym)
      if sym.children and #sym.children > 0 then
        _collect_enclosing(sym.children, line0, chain)
      end
      return
    end
  end
end

---@param bufnr integer
---@param line integer 1-based line number
---@return keystone.util.SymbolInfo[]
local function _get_chain(bufnr, line)
  local symbols = _symbol_cache[bufnr]
  if not symbols or #symbols == 0 then return {} end
  local line0 = line - 1
  local chain = {}
  if symbols[1] and symbols[1].range then
    _collect_enclosing(symbols, line0, chain)
  else
    for _, sym in ipairs(symbols) do
      local r = sym.location and sym.location.range
      if r and _in_range(line0, r) then
        table.insert(chain, sym)
      end
    end
  end
  return chain
end

local function _emit_for_buf(bufnr)
  local curr = vim.api.nvim_get_current_win()
  local target = (vim.api.nvim_win_is_valid(curr) and vim.api.nvim_win_get_buf(curr) == bufnr) and curr or nil
  if not target then
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
        target = winid
        break
      end
    end
  end
  if not target then return end
  local cursor = vim.api.nvim_win_get_cursor(target)
  _signal:emit(bufnr, _get_chain(bufnr, cursor[1]))
end

local function _emit_current()
  local winid = vim.api.nvim_get_current_win()
  local cfg = vim.api.nvim_win_get_config(winid)
  if cfg.relative ~= "" then return end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  if vim.bo[bufnr].buftype ~= "" then return end
  if not _managed_bufs[bufnr] then return end
  local cursor = vim.api.nvim_win_get_cursor(winid)
  _signal:emit(bufnr, _get_chain(bufnr, cursor[1]))
end

local function _buf_has_symbol_client(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/documentSymbol" })
  return #clients > 0
end

local function _request_symbols(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/documentSymbol" })
  local client = clients[1]
  if not client then return end
  local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
  client:request("textDocument/documentSymbol", params, function(err, result)
    if err or not result then return end
    _symbol_cache[bufnr] = result
    vim.schedule(function() _emit_for_buf(bufnr) end)
  end, bufnr)
end

local function _get_refresh_fn(bufnr)
  if not _refresh_fns[bufnr] then
    _refresh_fns[bufnr] = throttle.debounce_wrap(500, function()
      _request_symbols(bufnr)
    end)
  end
  return _refresh_fns[bufnr]
end

local function _activate()
  if _active then return end
  _active = true

  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(winid)
    if cfg.relative == "" then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].buftype == "" and _buf_has_symbol_client(bufnr) then
        _managed_bufs[bufnr] = true
        _request_symbols(bufnr)
      end
    end
  end

  local group = vim.api.nvim_create_augroup(_augroup_name, { clear = true })

  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local bufnr = args.buf
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client or not client:supports_method("textDocument/documentSymbol") then return end
      _managed_bufs[bufnr] = true
      _request_symbols(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("LspDetach", {
    group = group,
    callback = function(args)
      local bufnr = args.buf
      vim.schedule(function()
        if _managed_bufs[bufnr] and not _buf_has_symbol_client(bufnr) then
          _managed_bufs[bufnr] = nil
          _symbol_cache[bufnr] = nil
          _signal:emit(bufnr, {})
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(args)
      if _managed_bufs[args.buf] then
        _get_refresh_fn(args.buf)()
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = _emit_current,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args)
      _refresh_fns[args.buf] = nil
      _symbol_cache[args.buf] = nil
      _managed_bufs[args.buf] = nil
    end,
  })
end

local function _deactivate()
  if not _active then return end
  _active = false
  vim.api.nvim_del_augroup_by_name(_augroup_name)
  _refresh_fns = {}
  _symbol_cache = {}
  _managed_bufs = {}
end

---@class keystone.util.lspsymbol
local M = {}

---Subscribe to LSP symbol path changes.
---
---`fn` is called with `(bufnr, chain)` whenever the symbol context changes for a
---tracked buffer — on cursor movement or when LSP returns updated symbols.
---`chain` is ordered outermost-to-innermost and contains all enclosing symbols.
---
---LSP tracking is activated lazily on the first subscription and torn down when
---the last subscriber unsubscribes.
---
---@param fn fun(bufnr: integer, chain: keystone.util.SymbolInfo[])
---@return fun() unsubscribe
function M.subscribe(fn)
  local unsub = _signal:subscribe(fn)
  if #_signal._listeners == 1 then
    _activate()
  end
  return function()
    unsub()
    if #_signal._listeners == 0 then
      _deactivate()
    end
  end
end

return M
