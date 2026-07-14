local M = {}

local _throttle = require("keystone.tk.throttle")

local _uv = vim.uv or vim.loop

-- ---------------------------------------------------------------------------
-- Rolling log
-- ---------------------------------------------------------------------------

-- Neovim never rotates `lsp.log`; it only warns once it passes 1 GB. When
-- `lsp_rolling_log` is enabled we cap the file ourselves: the live log is
-- copied to `lsp.log.1` (shifting older `.N` files up to `keep`), then
-- truncated in place. Truncating in place -- rather than renaming -- is
-- deliberate: Neovim caches an append-mode handle to the live file, so a
-- rename would leave it writing into the rotated copy. An O_APPEND write
-- after truncation lands at offset 0, giving a clean new file.

---@type keystone.lspconfig.RollingLogConfig
local _ROLL_DEFAULTS = { max_bytes = 5 * 1024 * 1024, keep = 3 }

---@return keystone.lspconfig.RollingLogConfig? nil when rolling is disabled
local function _rolling_opts()
  local roll = M.config.lsp_rolling_log
  if not roll then return nil end
  if roll == true then return _ROLL_DEFAULTS end
  return vim.tbl_extend("force", _ROLL_DEFAULTS, roll --[[@as table]])
end

---@param path string live log path
---@param keep integer number of rotated files to retain
local function _rotate_log(path, keep)
  for i = keep - 1, 1, -1 do
    if _uv.fs_stat(path .. "." .. i) then
      _uv.fs_rename(path .. "." .. i, path .. "." .. (i + 1))
    end
  end
  if keep >= 1 then
    _uv.fs_copyfile(path, path .. ".1")
  end
  local fd = _uv.fs_open(path, "w", 420) -- truncate in place (0644)
  if fd then _uv.fs_close(fd) end
end

-- Rotate the live log if rolling is enabled and it has grown past the cap.
local function _maybe_rotate()
  local roll = _rolling_opts()
  if not roll then return end
  local path = require("vim.lsp.log").get_filename()
  local stat = _uv.fs_stat(path)
  if stat and stat.size > roll.max_bytes then
    _rotate_log(path, roll.keep)
  end
end

-- Neovim's `vim.lsp.log` opens (and writes a "[START] ... LSP logging initiated"
-- header to) the log file *before* it checks the level, so even at "OFF" the
-- file is created the moment a server logs to stderr. Wrap the loggers once so
-- nothing reaches the file while the level is "OFF". The level is read live on
-- every call, so toggling it at runtime works in both directions; every other
-- level is passed straight through unchanged. The same wrapper drives rolling:
-- every `_ROLL_CHECK_EVERY` writes it checks the size and rotates if needed.
local _ROLL_CHECK_EVERY = 64
local _write_count = 0
do
  local log = require("vim.lsp.log")
  for _, name in ipairs({ "trace", "debug", "info", "warn", "error" }) do
    local orig = log[name]
    log[name] = function(...)
      if log.get_level() == log.levels.OFF then return false end
      local ret = orig(...)
      _write_count = _write_count + 1
      if _write_count >= _ROLL_CHECK_EVERY then
        _write_count = 0
        _maybe_rotate()
      end
      return ret
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

---@class keystone.lspconfig.RollingLogConfig
---@field max_bytes integer rotate the live LSP log once it grows past this many bytes
---@field keep integer number of rotated files to retain (lsp.log.1 .. lsp.log.<keep>)

---@class keystone.lspconfig.Config
---@field enabled boolean
---@field servers string[]|"all" server names to enable; "all" discovers every config found in `lsp/` runtime dirs
---@field auto_enable boolean enable `servers` automatically on setup (the main thing vanilla Neovim does not do)
---@field format keystone.lspconfig.FormatConfig
---@field inlay_hints boolean turn on inlay hints for clients that support them
---@field document_highlight boolean highlight references of the symbol under the cursor (CursorMoved)
---@field signature_help boolean show signature help in a float while typing (CursorMovedI)
---@field log_level string?|integer LSP client log level for `vim.lsp.set_log_level`
---@field lsp_rolling_log boolean|keystone.lspconfig.RollingLogConfig cap the LSP log file size; `true` uses defaults, a table overrides them, `false` disables
---@field diagnostics vim.diagnostic.Opts|false passed to `vim.diagnostic.config`; false leaves diagnostics untouched
---@field capabilities? lsp.ClientCapabilities|fun():lsp.ClientCapabilities merged into every server's capabilities
---@field settings? table<string, vim.lsp.Config> per-server config overrides, e.g. { lua_ls = { settings = {...} } }
---@field on_attach? fun(client: vim.lsp.Client, bufnr: integer) extra per-buffer setup hook

---@return keystone.lspconfig.Config
local function _get_default_config()
  ---@type keystone.lspconfig.Config
  return {
    enabled            = true,
    servers            = "all",
    auto_enable        = true,
    format             = {
      on_save    = false,
      async      = false,
      timeout_ms = 2000,
      filter     = nil,
    },
    inlay_hints        = true,
    document_highlight = true,
    signature_help     = true,
    log_level          = nil,
    lsp_rolling_log    = true,
    diagnostics        = {
      virtual_text     = { spacing = 2, prefix = "●" },
      --virtual_lines    = { current_line = true, },
      signs            = false,
      underline        = false,
      update_in_insert = false,
      severity_sort    = true,
      float            = { border = "rounded", source = true },
    },
    capabilities       = nil,
    settings           = nil,
    on_attach          = nil,
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

local _sig_help_ns = vim.api.nvim_create_namespace("keystone_signature_help")

-- Show signature help in a float on cursor movement in insert mode. The
-- signature's own documentation is stripped so the float stays compact.
---@param client vim.lsp.Client
---@param bufnr integer
local function _setup_signature_help(client, bufnr)
  local _request_id = 0
  local _win --- @type integer?
  local _buf --- @type integer?

  local function _close()
    if _win and vim.api.nvim_win_is_valid(_win) then
      vim.api.nvim_win_close(_win, true)
    end
    _win = nil
    _buf = nil
  end

  local _request = _throttle.debounce_wrap(100, function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    _request_id = _request_id + 1
    local request_id = _request_id
    local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
    client:request("textDocument/signatureHelp", params, function(err, result)
      if request_id ~= _request_id then return end
      if err or not result or not result.signatures or #result.signatures == 0 then
        _close()
        return
      end

      local triggers = vim.tbl_get(client.server_capabilities, "signatureHelpProvider", "triggerCharacters")
      local ft = vim.bo[bufnr].filetype
      local lines, hl = vim.lsp.util.convert_signature_help_to_markdown_lines(result, ft, triggers)
      if not lines or vim.tbl_isempty(lines) then
        _close()
        return
      end

      if _win and vim.api.nvim_win_is_valid(_win) and _buf and vim.api.nvim_buf_is_valid(_buf) then
        vim.bo[_buf].modifiable = true
        vim.api.nvim_buf_set_lines(_buf, 0, -1, false, lines)
        vim.bo[_buf].modifiable = false
      else
        local fbuf, fwin = vim.lsp.util.open_floating_preview(lines, "markdown", {
          silent       = true,
          border       = "rounded",
          focusable    = false,
          focus        = false,
          close_events = { "InsertLeave", "BufHidden" },
        })
        _win = fwin
        _buf = fbuf
      end

      if hl then
        vim.hl.range(_buf, _sig_help_ns, "LspSignatureActiveParameter", { hl[1], hl[2] }, { hl[3], hl[4] })
      end
    end, bufnr)
  end)

  vim.api.nvim_create_autocmd({ "InsertEnter", "CursorMovedI" }, {
    group    = vim.api.nvim_create_augroup(_group .. "_sighelp_" .. bufnr, { clear = true }),
    buffer   = bufnr,
    callback = function()
      if vim.api.nvim_win_get_config(0).relative ~= "" then return end
      _request()
    end,
  })

  vim.api.nvim_create_autocmd({ "InsertLeave", "BufWipeout" }, {
    group    = vim.api.nvim_create_augroup(_group .. "_sighelp_cleanup_" .. bufnr, { clear = true }),
    buffer   = bufnr,
    callback = _close,
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

  if M.config.signature_help
      and client:supports_method("textDocument/signatureHelp")
  then
    _setup_signature_help(client, bufnr)
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
  _enabled = true

  if M.config.log_level ~= nil then
    require("vim.lsp.log").set_level(M.config.log_level)
  end

  _maybe_rotate()

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

---@param opts keystone.lspconfig.Config?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

  if M.config.enabled then
    M.enable()
  else
    M.disable()
  end
end

return M
