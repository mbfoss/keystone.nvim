---Symbol path section provider.
---
---Shows the chain of enclosing LSP symbols (class/method/function/...) at the
---cursor. Document symbols are tracked per buffer via the LSP document-symbol
---request and refreshed on edits; the section redraws as the cursor moves.
local M = {}

local throttle = require("keystone.tk.throttle")

local _AUGROUP = "keystone_statusline_symbol_path"

-- [bufnr] = DocumentSymbol[] | SymbolInformation[]
local _symbol_cache = {}
-- bufnrs with a document-symbol-capable client attached
local _tracked_bufs = {}
-- per-buffer debounced refresh functions (created lazily on first TextChanged)
local _refresh_fns = {}
-- called whenever the tracked state changes, so the statusline can redraw
local _on_change = nil

local _KIND_ICONS = {
  [1]  = "󰈙", -- File
  [2]  = "󰆧", -- Module
  [3]  = "󰌗", -- Namespace
  [4]  = "󰏗", -- Package
  [5]  = "󰌗", -- Class
  [6]  = "󰆧", -- Method
  [7]  = "󰜢", -- Property
  [8]  = "󰇽", -- Field
  [9]  = "", -- Constructor
  [10] = "󰕘", -- Enum
  [11] = "", -- Interface
  [12] = "󰊕", -- Function
  [13] = "󰀫", -- Variable
  [14] = "󰏿", -- Constant
  [22] = "󰕘", -- EnumMember
  [23] = "󰙅", -- Struct
  [25] = "󰆕", -- Operator
  [26] = "󰊄", -- TypeParameter
}

-- Class=5, Method=6, Constructor=9, Function=12, Struct=23
local _FUNCTION_KINDS = { [5] = true, [6] = true, [9] = true, [12] = true, [23] = true }

---@type table<string, vim.api.keyset.highlight>
M.highlights = {
  KeystoneSLSymbolPath = { link = "Statusbar" },
}

local function _in_range(line0, range)
  return line0 >= range.start.line and line0 <= range["end"].line
end

local function _collect_enclosing(symbols, line0, chain)
  for _, sym in ipairs(symbols) do
    if sym.range and _in_range(line0, sym.range) then
      if _FUNCTION_KINDS[sym.kind] then
        table.insert(chain, sym)
      end
      if sym.children and #sym.children > 0 then
        _collect_enclosing(sym.children, line0, chain)
      end
      return
    end
  end
end

---@param symbols table[]?
---@param line integer 1-based cursor line
---@return string
local function _build_symbol_trail(symbols, line)
  if not symbols or #symbols == 0 then return "" end
  local line0 = line - 1

  local chain = {}
  if symbols[1] and symbols[1].range then
    -- DocumentSymbol tree
    _collect_enclosing(symbols, line0, chain)
  else
    -- SymbolInformation flat list
    for _, sym in ipairs(symbols) do
      local r = sym.location and sym.location.range
      if r and _in_range(line0, r) and _FUNCTION_KINDS[sym.kind] then
        table.insert(chain, sym)
      end
    end
  end

  if #chain == 0 then return "" end

  local parts = {}
  for _, sym in ipairs(chain) do
    local kind_icon = _KIND_ICONS[sym.kind] or "󰊕"
    local name = sym.name:gsub("%%", "%%%%")
    table.insert(parts, kind_icon .. " " .. name)
  end

  return "%#KeystoneSLSymbolPath# " .. table.concat(parts, " › ") .. " %*"
end

---@param bufnr integer
---@return string
function M.render(bufnr)
  local winid = vim.g.statusline_winid
  if not winid or winid == 0 then
    winid = vim.api.nvim_get_current_win()
  end
  if not vim.api.nvim_win_is_valid(winid) then return "" end
  if vim.api.nvim_win_get_buf(winid) ~= bufnr then return "" end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  return _build_symbol_trail(_symbol_cache[bufnr], cursor[1])
end

---@param bufnr integer
local function _request_symbols(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/documentSymbol" })
  local client = clients[1]
  if not client then return end

  local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
  client:request("textDocument/documentSymbol", params, function(err, result)
    if err or not result then return end
    _symbol_cache[bufnr] = result
    if _on_change then _on_change() end
  end, bufnr)
end

---@param bufnr integer
local function _get_refresh_fn(bufnr)
  if not _refresh_fns[bufnr] then
    _refresh_fns[bufnr] = throttle.debounce_wrap(500, function()
      _request_symbols(bufnr)
    end)
  end
  return _refresh_fns[bufnr]
end

---@param bufnr integer
---@return boolean
local function _buf_has_symbol_client(bufnr)
  return #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/documentSymbol" }) > 0
end

---@param on_change fun() called whenever the tracked symbol state changes
function M.enable(on_change)
  _on_change = on_change
  local group = vim.api.nvim_create_augroup(_AUGROUP, { clear = true })

  -- Pick up buffers that already have a symbol-capable client attached.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and _buf_has_symbol_client(bufnr) then
      _tracked_bufs[bufnr] = true
      _request_symbols(bufnr)
    end
  end

  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client or not client:supports_method("textDocument/documentSymbol") then return end
      _tracked_bufs[args.buf] = true
      _request_symbols(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("LspDetach", {
    group = group,
    callback = function(args)
      local bufnr = args.buf
      -- Schedule so the client list reflects the detach before we check.
      vim.schedule(function()
        if _tracked_bufs[bufnr] and not _buf_has_symbol_client(bufnr) then
          _tracked_bufs[bufnr] = nil
          _symbol_cache[bufnr] = nil
          if _on_change then _on_change() end
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(args)
      if _tracked_bufs[args.buf] then
        _get_refresh_fn(args.buf)()
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(args)
      if _tracked_bufs[args.buf] and _on_change then _on_change() end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args)
      _refresh_fns[args.buf] = nil
      _symbol_cache[args.buf] = nil
      _tracked_bufs[args.buf] = nil
    end,
  })
end

function M.disable()
  _on_change = nil
  vim.api.nvim_del_augroup_by_name(_AUGROUP)
  _refresh_fns = {}
  _symbol_cache = {}
  _tracked_bufs = {}
end

return M
