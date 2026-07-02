local M = {}

local _usercmd = require("keystone.tk.usercmd")

-- Neovim's `vim.lsp.log` opens (and writes a "[START] ... LSP logging initiated"
-- header to) the log file *before* it checks the level, so even at "OFF" the
-- file is created the moment a server logs to stderr. Wrap the loggers once so
-- nothing reaches the file while the level is "OFF". The level is read live on
-- every call, so toggling it at runtime works in both directions; every other
-- level is passed straight through unchanged.
do
  local log = require("vim.lsp.log")
  for _, name in ipairs({ "trace", "debug", "info", "warn", "error" }) do
    local orig = log[name]
    log[name] = function(...)
      if log.get_level() == log.levels.OFF then return false end
      return orig(...)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------


---@class keystone.lspconfig.FormatConfig
---@field on_save boolean format the buffer on `BufWritePre`
---@field async boolean
---@field timeout_ms integer
---@field filter? fun(client: vim.lsp.Client): boolean only format with clients for which this returns true

---@class keystone.lspconfig.Config
---@field enabled boolean
---@field servers string[]|"all" server names to enable; "all" discovers every config found in `lsp/` runtime dirs
---@field auto_enable boolean enable `servers` automatically on setup (the main thing vanilla Neovim does not do)
---@field format keystone.lspconfig.FormatConfig
---@field inlay_hints boolean turn on inlay hints for clients that support them
---@field document_highlight boolean highlight references of the symbol under the cursor (CursorMoved)
---@field log_level string|integer LSP client log level for `vim.lsp.set_log_level` (e.g. "ERROR", "WARN", "DEBUG", "OFF")
---@field diagnostics vim.diagnostic.Opts|false passed to `vim.diagnostic.config`; false leaves diagnostics untouched
---@field capabilities? lsp.ClientCapabilities|fun():lsp.ClientCapabilities merged into every server's capabilities
---@field settings? table<string, vim.lsp.Config> per-server config overrides, e.g. { lua_ls = { settings = {...} } }
---@field on_attach? fun(client: vim.lsp.Client, bufnr: integer) extra per-buffer setup hook

---@return keystone.lspconfig.Config
local function _get_default_config()
  ---@type keystone.lspconfig.Config
  return {
    enabled      = true,
    servers      = "all",
    auto_enable  = true,
    format       = {
      on_save    = false,
      async      = false,
      timeout_ms = 2000,
      filter     = nil,
    },
    inlay_hints  = true,
    document_highlight = true,
    log_level    = "OFF",
    diagnostics  = {
      virtual_text     = { spacing = 2, prefix = "●" },
      --virtual_lines    = { current_line = true, },
      signs            = false,
      underline        = false,
      update_in_insert = false,
      severity_sort    = true,
      float            = { border = "rounded", source = true },
    },
    capabilities = nil,
    settings     = nil,
    on_attach    = nil,
  }
end

---@type keystone.lspconfig.Config
M.config = _get_default_config()

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local _enabled = false
local _group = "keystone_lspconfig"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function _has_api()
  return vim.lsp.enable ~= nil and vim.lsp.config ~= nil
end

-- Discover every server that has an `lsp/<name>.lua` config on the runtimepath.
-- These come from nvim-lspconfig, the user's own config dir, or other plugins.
---@return string[]
local function _discover_servers()
  local seen, out = {}, {}
  for _, path in ipairs(vim.api.nvim_get_runtime_file("lsp/*.lua", true)) do
    local name = vim.fn.fnamemodify(path, ":t:r")
    if name ~= "" and not seen[name] then
      seen[name] = true
      table.insert(out, name)
    end
  end
  table.sort(out)
  return out
end

---@return string[]
local function _resolve_servers()
  if M.config.servers == "all" then
    return _discover_servers()
  end
  return M.config.servers --[[@as string[] ]]
end

---@param client vim.lsp.Client
local function _can_format(client)
  if not client:supports_method("textDocument/formatting") then return false end
  if M.config.format.filter then return M.config.format.filter(client) end
  return true
end

---@param client vim.lsp.Client
---@param bufnr integer
local function _setup_format_on_save(client, bufnr)
  if not M.config.format.on_save or not _can_format(client) then return end
  vim.api.nvim_create_autocmd("BufWritePre", {
    group    = vim.api.nvim_create_augroup(_group .. "_format_" .. bufnr, { clear = true }),
    buffer   = bufnr,
    callback = function()
      vim.lsp.buf.format({
        bufnr      = bufnr,
        async      = M.config.format.async,
        timeout_ms = M.config.format.timeout_ms,
        filter     = M.config.format.filter,
      })
    end,
  })
end

---@param bufnr integer
local function _setup_document_highlight(bufnr)
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group    = vim.api.nvim_create_augroup(_group .. "_highlight_" .. bufnr, { clear = true }),
    buffer   = bufnr,
    callback = function()
      vim.lsp.buf.clear_references()
      vim.lsp.buf.document_highlight()
    end,
  })
end

---@param client vim.lsp.Client
---@param bufnr integer
local function _on_attach(client, bufnr)
  if M.config.inlay_hints
      and client:supports_method("textDocument/inlayHint")
      and vim.lsp.inlay_hint
  then
    vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
  end

  _setup_format_on_save(client, bufnr)

  if M.config.document_highlight
      and client:supports_method("textDocument/documentHighlight")
  then
    _setup_document_highlight(bufnr)
  end

  if M.config.on_attach then
    M.config.on_attach(client, bufnr)
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Enable LSP servers. With no argument, enables the configured `servers`
-- (resolving "all" to whatever is on the runtimepath).
---@param servers? string[]|"all"
function M.enable_servers(servers)
  if not _has_api() then return {} end

  local names
  if servers == nil then
    names = _resolve_servers()
  elseif servers == "all" then
    names = _discover_servers()
  else
    names = servers
  end

  if #names > 0 then
    vim.lsp.enable(names)
  end
  return names
end

function M.enable()
  if _enabled then return end
  if not _has_api() then
    vim.notify(
      "[keystone.nvim] lspconfig module requires Neovim >= 0.11 (vim.lsp.enable). Module disabled.",
      vim.log.levels.WARN
    )
    return
  end
  _enabled = true

  if M.config.log_level ~= nil then
    require("vim.lsp.log").set_level(M.config.log_level)
  end

  if M.config.diagnostics ~= false then
    vim.diagnostic.config(M.config.diagnostics)
  end

  -- Apply shared capabilities to every server via the wildcard config.
  local caps = M.config.capabilities
  if type(caps) == "function" then caps = caps() end
  if caps then
    vim.lsp.config("*", { capabilities = caps })
  end

  -- Per-server config overrides.
  for name, cfg in pairs(M.config.settings or {}) do
    vim.lsp.config(name, cfg)
  end

  local group = vim.api.nvim_create_augroup(_group, { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      if not _enabled then return end
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client then _on_attach(client, args.buf) end
    end,
  })

  if M.config.auto_enable then
    M.enable_servers()
  end
end

function M.disable()
  if not _enabled then return end
  _enabled = false
  pcall(vim.api.nvim_del_augroup_by_name, _group)
end

-- Stop and restart the LSP clients attached to a buffer (default: current).
---@param bufnr? integer
function M.restart(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if vim.tbl_isempty(clients) then
    vim.notify("[keystone.nvim] no LSP clients on this buffer", vim.log.levels.INFO)
    return
  end
  local names = vim.tbl_map(function(c) return c.name end, clients)
  for _, client in ipairs(clients) do
    client:stop()
  end
  vim.defer_fn(function()
    vim.lsp.enable(names)
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_exec_autocmds("FileType", { buffer = bufnr })
    end
  end, 200)
end

---@param bufnr? integer
function M.format(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  vim.lsp.buf.format({
    bufnr      = bufnr,
    async      = M.config.format.async,
    timeout_ms = M.config.format.timeout_ms,
    filter     = M.config.format.filter,
  })
end

-- Print a short summary: available servers, and which are attached here.
function M.info()
  local available = _discover_servers()
  local attached = vim.tbl_map(
    function(c) return c.name end,
    vim.lsp.get_clients({ bufnr = vim.api.nvim_get_current_buf() })
  )
  local lines = {
    "keystone.lspconfig",
    "  attached (this buffer): " .. (next(attached) and table.concat(attached, ", ") or "none"),
    "  available configs (" .. #available .. "): " .. (next(available) and table.concat(available, ", ") or "none"),
  }
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- User command
-- ---------------------------------------------------------------------------

local _subcommands = {
  info    = function() M.info() end,
  format  = function() M.format() end,
  restart = function() M.restart() end,
  log     = function() vim.cmd("edit " .. require("vim.lsp.log").get_filename()) end,
  enable  = function() M.enable_servers() end,
}

---@param _cmd string
---@param args string[]
local function _run(_cmd, args)
  local sub = args[1] or "info"
  local fn = _subcommands[sub]
  if not fn then
    vim.notify("[keystone.nvim] :Lsp unknown subcommand '" .. sub .. "'", vim.log.levels.ERROR)
    return
  end
  fn()
end

---@param _cmd string
---@param rest string[]
local function _complete(_cmd, rest)
  if #rest > 0 then return {} end
  return vim.tbl_keys(_subcommands)
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

---@param opts keystone.lspconfig.Config?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

  _usercmd.register_user_cmd("Lsp", _run, {
    desc = "keystone LSP control",
    subcommand_fn = _complete,
  })

  if M.config.enabled then
    M.enable()
  else
    M.disable()
  end
end

return M
