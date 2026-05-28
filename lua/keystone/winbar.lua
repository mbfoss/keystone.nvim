local M = {}

local uitool = require("keystone.util.uitool")

---@class keystone.winbar.Config
---@field enabled boolean

local function _get_default_config()
  ---@type keystone.winbar.Config
  return {
    enabled = true,
  }
end

---@type keystone.winbar.Config
M.config = _get_default_config()

-- [bufnr] = DocumentSymbol[] | SymbolInformation[]
local _symbol_cache = {}
-- [bufnr] = string  (file+icon part, stable across cursor moves)
local _file_cache = {}

local _KIND_ICONS = {
  [1]  = "", -- File
  [2]  = "", -- Module
  [3]  = "󰅩", -- Namespace
  [4]  = "", -- Package
  [5]  = "", -- Class
  [6]  = "󰊕", -- Method
  [7]  = "", -- Property
  [8]  = "󰏿", -- Field
  [9]  = "󰊕", -- Constructor
  [10] = "", -- Enum
  [11] = "󰜰", -- Interface
  [12] = "󰊕", -- Function
  [13] = "", -- Variable
  [14] = "", -- Constant
  [22] = "", -- EnumMember
  [23] = "󱂖", -- Struct
  [25] = "󰅪", -- Operator
  [26] = "󰊕", -- TypeParameter
}

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
      if r and _in_range(line0, r) then
        table.insert(chain, sym)
      end
    end
  end

  if #chain == 0 then return "" end

  local parts = {}
  for _, sym in ipairs(chain) do
    local kind_icon = _KIND_ICONS[sym.kind] or "󰊕"
    local name = sym.name:gsub("%%", "%%%%")
    table.insert(parts, "%#WinBar# " .. kind_icon .. " %#WinBar#" .. name)
  end

  return "%#WinBar# ›" .. table.concat(parts, " %#WinBar#›")
end

-- Crops a winbar string (containing %#HlGroup# sequences) from the left,
-- keeping the rightmost content when it exceeds max_width display columns.
local function _fit_to_width(str, max_width)
  local plain = (str:gsub("%%#[^#]*#", ""))
  if vim.fn.strwidth(plain) <= max_width then return str end

  local keep_width = max_width - vim.fn.strwidth("…")
  local plain_width = vim.fn.strwidth(plain)
  local target_drop = plain_width - keep_width

  local dropped = 0
  local i = 1
  local n = #str
  local result = {}
  local pending_hl = "%#WinBar#"
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

  return "%#WinBar#…" .. table.concat(result)
end

local function _build_file_part(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return "%#WinBar#[No Name]"
  end

  local rel = vim.fn.fnamemodify(name, ":~:.")
  local dir = vim.fn.fnamemodify(rel, ":h")
  local filename = vim.fn.fnamemodify(rel, ":t")

  if dir and dir ~= "." and dir ~= "" then
    return "%#WinBar#" .. dir:gsub("%%", "%%%%") .. "/%#WinBar#" .. filename:gsub("%%", "%%%%")
  end
  return "%#WinBar#" .. filename:gsub("%%", "%%%%")
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

    if not _file_cache[bufnr] then
      _file_cache[bufnr] = _build_file_part(bufnr)
    end
    local cursor = vim.api.nvim_win_get_cursor(winid)
    local sym_trail = _build_symbol_trail(_symbol_cache[bufnr], cursor[1])
    local width = uitool.get_window_width(winid)
    return _fit_to_width(" " .. _file_cache[bufnr] .. sym_trail, width)
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
  vim.wo[winid].winbar = '%{%v:lua.require("keystone.winbar").render()%}'
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

local _enabled = false

function M.enable()
  if _enabled then return end
  _enabled = true

  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if _is_regular_win(winid) then
      _set_winbar(winid)
    end
  end

  local group = vim.api.nvim_create_augroup("keystone_winbar", { clear = true })

  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = group,
    callback = function()
      local winid = vim.api.nvim_get_current_win()
      if not _is_regular_win(winid) then return end
      _set_winbar(winid)
      local bufnr = vim.api.nvim_win_get_buf(winid)
      _request_symbols(bufnr)
    end,
  })

  -- Invalidate file part cache when buffer name or write changes
  vim.api.nvim_create_autocmd({ "BufWritePost", "BufFilePost" }, {
    group = group,
    callback = function(args)
      _file_cache[args.buf] = nil
      _request_symbols(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      _request_symbols(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(args)
      _symbol_cache[args.buf] = nil
      _file_cache[args.buf] = nil
    end,
  })
end

function M.disable()
  if not _enabled then return end
  _enabled = false
  vim.api.nvim_del_augroup_by_name("keystone_winbar")
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      vim.wo[winid].winbar = ""
    end
  end
  _symbol_cache = {}
  _file_cache = {}
end

---@param opts keystone.winbar.Config?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
  if M.config.enabled then
    M.enable()
  else
    M.disable()
  end
end

return M
