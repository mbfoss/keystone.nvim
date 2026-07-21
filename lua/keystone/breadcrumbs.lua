local M = {}

local throttle = require("keystone.tk.throttle")
local usercmd = require("keystone.tk.usercmd")

---@class keystone.breadcrumbs.Config
---@field enabled boolean Enable breadcrumbs on setup (default: false)

local function _get_default_config()
  ---@type keystone.breadcrumbs.Config
  return {
    enabled = false,
  }
end

---@type keystone.breadcrumbs.Config
M.config = _get_default_config()

-- [bufnr] = DocumentSymbol[] | SymbolInformation[]
local _symbol_cache = {}

-- bufnrs where we own the winbar
local _managed_bufs = {}

-- per-buffer debounced refresh functions (created lazily on first TextChanged)
local _refresh_fns = {}

local _OUR_WINBAR = '%{%v:lua.require("keystone.breadcrumbs").render()%}'

local _AUGROUP = "keystone_breadcrumbs"

local _KIND_ICONS = {
  [1]  = "󰈙", -- File
  [2]  = "󰆧", -- Module
  [3]  = "󰌗", -- Namespace
  [4]  = "󰏗", -- Package
  [5]  = "󰌗", -- Class
  [6]  = "󰆧", -- Method
  [7]  = "󰜢", -- Property
  [8]  = "󰇽", -- Field
  [9]  = "", -- Constructor
  [10] = "󰕘", -- Enum
  [11] = "", -- Interface
  [12] = "󰊕", -- Function
  [13] = "󰀫", -- Variable
  [14] = "󰏿", -- Constant
  [22] = "󰕘", -- EnumMember
  [23] = "󰙅", -- Struct
  [25] = "󰆕", -- Operator
  [26] = "󰊄", -- TypeParameter
}

local function _in_range(line0, range)
  return line0 >= range.start.line and line0 <= range["end"].line
end

-- Class=5, Method=6, Constructor=9, Function=12, Struct=23
local _FUNCTION_KINDS = { [5] = true, [6] = true, [9] = true, [12] = true, [23] = true }

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
    table.insert(parts, "%* " .. kind_icon .. " %*" .. name)
  end

  return "%* ›" .. table.concat(parts, " %*›")
end

-- Crops a winbar string (containing %#HlGroup# sequences) from the left,
-- keeping the rightmost content when it exceeds max_width display columns.
local function _fit_to_width(str, max_width)
  local plain = (str:gsub("%%#[^#]*#", ""):gsub("%%%*", ""))
  if vim.fn.strwidth(plain) <= max_width then return str end

  local keep_width = max_width - vim.fn.strwidth("…")
  local plain_width = vim.fn.strwidth(plain)
  local target_drop = plain_width - keep_width

  local dropped = 0
  local i = 1
  local n = #str
  local result = {}
  local pending_hl = "%*"
  local collecting = false

  while i <= n do
    if str:sub(i, i) == "%" and i < n and str:sub(i + 1, i + 1) == "#" then
      local j = str:find("#", i + 2)
      if j then
        if collecting then
          table.insert(result, str:sub(i, j))
        else
          pending_hl = str:sub(i, j)
        end
        i = j + 1
      else
        i = i + 1
      end
    elseif str:sub(i, i) == "%" and i < n and str:sub(i + 1, i + 1) == "*" then
      if collecting then
        table.insert(result, "%*")
      else
        pending_hl = "%*"
      end
      i = i + 2
    else
      local b = str:byte(i)
      local clen = b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
      local ch = str:sub(i, i + clen - 1)
      if collecting then
        table.insert(result, ch)
      else
        dropped = dropped + vim.fn.strwidth(ch)
        if dropped >= target_drop then
          collecting = true
          table.insert(result, pending_hl)
        end
      end
      i = i + clen
    end
  end

  return "%*…" .. table.concat(result)
end

function M.render()
  local ok, result = pcall(function()
    local winid = vim.g.statusline_winid
    if not winid or winid == 0 then
      winid = vim.api.nvim_get_current_win()
    end
    if not vim.api.nvim_win_is_valid(winid) then return "" end
    local cfg = vim.api.nvim_win_get_config(winid)
    if cfg.relative ~= "" then return "" end
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if vim.bo[bufnr].buftype ~= "" then return "" end

    local name = vim.api.nvim_buf_get_name(bufnr)
    name = vim.fn.fnamemodify(name, ":t"):gsub("%%", "%%%%")
    local prefix = "%* " .. name

    local cursor = vim.api.nvim_win_get_cursor(winid)
    local sym_trail = _build_symbol_trail(_symbol_cache[bufnr], cursor[1])
    local width = vim.api.nvim_win_get_width(winid)
    return _fit_to_width(prefix .. sym_trail, width)
  end)
  return ok and result or ""
end

local function _is_regular_win(winid)
  if not vim.api.nvim_win_is_valid(winid) then return false end
  local cfg = vim.api.nvim_win_get_config(winid)
  if cfg.relative ~= "" then return false end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  return vim.bo[bufnr].buftype == ""
end

local function _set_winbar(winid)
  local current = vim.wo[winid].winbar
  if current == "" or current == _OUR_WINBAR then
    vim.wo[winid].winbar = _OUR_WINBAR
  end
end

local function _clear_winbar(winid)
  if vim.api.nvim_win_is_valid(winid) and vim.wo[winid].winbar == _OUR_WINBAR then
    vim.wo[winid].winbar = ""
  end
end

local function _apply_to_buf_wins(bufnr, fn)
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid)
        and vim.api.nvim_win_get_buf(winid) == bufnr
        and _is_regular_win(winid)
    then
      fn(winid)
    end
  end
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
    vim.schedule(function()
      vim.cmd("redrawstatus!")
    end)
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

local _enabled = false

function M.enable()
  if _enabled then return end
  _enabled = true

  -- Apply to any buffers that already have LSP attached (e.g. setup() called late)
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if _is_regular_win(winid) then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if _buf_has_symbol_client(bufnr) then
        _managed_bufs[bufnr] = true
        _set_winbar(winid)
        _request_symbols(bufnr)
      end
    end
  end

  local group = vim.api.nvim_create_augroup(_AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = group,
    callback = function()
      local winid = vim.api.nvim_get_current_win()
      if not _is_regular_win(winid) then return end
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if _managed_bufs[bufnr] then
        _set_winbar(winid)
        _request_symbols(bufnr)
      end
    end,
  })

  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local bufnr = args.buf
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client or not client:supports_method("textDocument/documentSymbol") then return end
      _managed_bufs[bufnr] = true
      _apply_to_buf_wins(bufnr, _set_winbar)
      _request_symbols(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("LspDetach", {
    group = group,
    callback = function(args)
      local bufnr = args.buf
      -- Schedule so the client list reflects the detach before we check
      vim.schedule(function()
        if _managed_bufs[bufnr] and not _buf_has_symbol_client(bufnr) then
          _managed_bufs[bufnr] = nil
          _symbol_cache[bufnr] = nil
          _apply_to_buf_wins(bufnr, _clear_winbar)
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

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args)
      _refresh_fns[args.buf] = nil
      _symbol_cache[args.buf] = nil
      _managed_bufs[args.buf] = nil
    end,
  })
end

function M.disable()
  if not _enabled then return end
  _enabled = false
  vim.api.nvim_del_augroup_by_name(_AUGROUP)
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    _clear_winbar(winid)
  end
  _refresh_fns = {}
  _symbol_cache = {}
  _managed_bufs = {}
end

---@return boolean
function M.is_enabled()
  return _enabled
end

--- Toggles breadcrumbs on/off.
---@return boolean enabled the state after toggling
function M.toggle()
  if _enabled then
    M.disable()
  else
    M.enable()
  end
  return _enabled
end

---@type table<string, fun()>
local _SUBCOMMANDS = {
  enable = function() M.enable() end,
  disable = function() M.disable() end,
  toggle = function() M.toggle() end,
}

local function _register_user_cmd()
  usercmd.register_user_cmd("Breadcrumbs", function(_, args)
    local action = args[1] or "toggle"
    local fn = _SUBCOMMANDS[action]
    if not fn then
      vim.notify("Breadcrumbs: unknown action " .. vim.inspect(action), vim.log.levels.WARN)
      return
    end
    fn()
  end, {
    desc = "Enable, disable or toggle LSP breadcrumbs in the winbar",
    subcommand = function(_, rest)
      if #rest > 0 then return {} end
      return vim.tbl_keys(_SUBCOMMANDS)
    end,
  })
end

---@param opts keystone.breadcrumbs.Config?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
  _register_user_cmd()
  if M.config.enabled then
    M.enable()
  else
    M.disable()
  end
end

return M
