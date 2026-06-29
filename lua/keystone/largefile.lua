local M = {}

-- ---------------------------------------------------------------------------
-- Large file handling
--
-- Opening a large file is slow mostly because of work Neovim does *eagerly* on
-- read: syntax highlighting, treesitter parsing, LSP attach, folding, swap and
-- undo bookkeeping. This module detects a large buffer in `BufReadPre` (before
-- any of that runs) and strips the expensive machinery for that buffer only,
-- leaving normal files untouched.
--
-- A file is "large" when it exceeds `size_threshold` bytes, or when any single
-- line is longer than `long_line_threshold`. Very long lines are checked in
-- `BufReadPost` because they wreck regex-based syntax even in otherwise small
-- files.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

---@class keystone.largefile.Config
---@field enabled boolean? master switch; when false `setup` tears the handler down
---@field size_threshold integer? byte size above which a file is treated as large
---@field long_line_threshold integer? a file with any line longer than this is treated as large
---@field disable_syntax boolean? turn off Vim syntax highlighting
---@field disable_treesitter boolean? stop nvim-treesitter highlight/indent attaching
---@field disable_lsp boolean? detach (and block) language servers for the buffer
---@field disable_folding boolean? set `foldmethod=manual` and open all folds
---@field disable_swapfile boolean? clear `swapfile` for the buffer
---@field disable_undofile boolean? clear `undofile` (and shorten undolevels)
---@field disable_matchparen boolean? skip the matchparen highlight on the buffer
---@field undolevels integer? `undolevels` to use when `disable_undofile` is set
---@field synmaxcol integer? `synmaxcol` to clamp to (caps per-line syntax cost)
---@field notify boolean? emit a message when a buffer is opened in large-file mode

---@return keystone.largefile.Config
local function _get_default_config()
  ---@type keystone.largefile.Config
  return {
    enabled             = true,
    size_threshold      = 1.5 * 1024 * 1024, -- 1.5 MiB
    long_line_threshold = 10000,
    disable_syntax      = true,
    disable_treesitter  = true,
    disable_lsp         = true,
    disable_folding     = true,
    disable_swapfile    = true,
    disable_undofile    = true,
    disable_matchparen  = true,
    undolevels          = -1,
    synmaxcol           = 256,
    notify              = true,
  }
end

---@type keystone.largefile.Config
M.config = _get_default_config()

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local _AUGROUP = "keystone.largefile"

-- Buffer-local flag name (read via `vim.b[bufnr].keystone_largefile`) so other
-- code/plugins can cheaply test whether a buffer is in large-file mode.
local _BUF_FLAG = "keystone_largefile"

-- ---------------------------------------------------------------------------
-- Detection
-- ---------------------------------------------------------------------------

--- Byte size of the file backing `bufnr`, or 0 when it has no readable file.
---@param bufnr integer
---@return integer
local function _file_size(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return 0 end
  local stat = vim.loop.fs_stat(name)
  return stat and stat.size or 0
end

--- True when any line in `bufnr` is longer than `long_line_threshold`.
--- Scans only a bounded sample from the head of the buffer so the check itself
--- stays cheap on huge files.
---@param bufnr integer
---@return boolean
local function _has_long_line(bufnr)
  local limit = M.config.long_line_threshold
  if not limit or limit <= 0 then return false end

  local sample = vim.api.nvim_buf_get_lines(bufnr, 0, 256, false)
  for _, line in ipairs(sample) do
    if #line > limit then return true end
  end
  return false
end

--- Whether `bufnr` should be opened in large-file mode based on its file size.
---@param bufnr integer
---@return boolean
local function _is_large_by_size(bufnr)
  local threshold = M.config.size_threshold
  if not threshold or threshold <= 0 then return false end
  return _file_size(bufnr) > threshold
end

-- ---------------------------------------------------------------------------
-- Application
-- ---------------------------------------------------------------------------

--- Tear down treesitter and LSP for `bufnr`. These attach *after* `BufReadPre`
--- (on `FileType`/`BufReadPost`), so the teardown is deferred to run once they
--- have had a chance to attach; otherwise there is nothing yet to detach.
---@param bufnr integer
local function _detach_attachers(bufnr)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    if M.config.disable_treesitter and vim.treesitter.highlighter.active[bufnr] then
      vim.treesitter.stop(bufnr)
      -- `stop` flips syntax back on; keep it off when we own this buffer.
      if M.config.disable_syntax then
        vim.bo[bufnr].syntax = "off"
      end
    end

    if M.config.disable_lsp then
      for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        vim.lsp.buf_detach_client(bufnr, client.id)
      end
    end
  end)
end

--- Apply the buffer-local optimizations to `bufnr`. Idempotent: re-applying on
--- an already-marked buffer is a no-op.
---@param bufnr integer
local function _apply(bufnr)
  if vim.b[bufnr][_BUF_FLAG] then return end
  vim.b[bufnr][_BUF_FLAG] = true

  local cfg = M.config
  local bo = vim.bo[bufnr]

  if cfg.disable_swapfile then bo.swapfile = false end

  if cfg.disable_undofile then
    bo.undofile = false
    bo.undolevels = cfg.undolevels or -1
  end

  if cfg.synmaxcol and cfg.synmaxcol > 0 then
    bo.synmaxcol = cfg.synmaxcol
  end

  if cfg.disable_syntax then
    bo.syntax = "off"
  end

  if cfg.disable_matchparen and vim.g.loaded_matchparen == 1 then
    -- matchparen is global (it has no buffer-local form); turning it off is the
    -- cheapest correct way to keep it from scanning this buffer.
    vim.cmd("NoMatchParen")
  end

  -- Folding is window-local, so it is applied in `BufWinEnter` (see `enable`);
  -- treesitter/LSP attach later and are stripped via the deferred teardown.
  if cfg.disable_treesitter or cfg.disable_lsp then
    _detach_attachers(bufnr)
  end

  if cfg.notify then
    local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
    vim.notify(
      ("keystone: %q opened in fast mode"):format(name),
      vim.log.levels.INFO
    )
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- True when `bufnr` (defaults to current) is in large-file mode.
---@param bufnr integer?
---@return boolean
function M.is_large(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return vim.b[bufnr][_BUF_FLAG] == true
end

--- Force `bufnr` (defaults to current) into large-file mode, regardless of size.
---@param bufnr integer?
function M.mark(bufnr)
  M.apply(bufnr)
end

--- Apply large-file mode to `bufnr` (defaults to current).
---@param bufnr integer?
function M.apply(bufnr)
  _apply(bufnr or vim.api.nvim_get_current_buf())
end

--- Install the detection autocmds.
function M.enable()
  local group = vim.api.nvim_create_augroup(_AUGROUP, { clear = true })

  -- Size check before the file is read, so syntax/ft machinery never spins up.
  vim.api.nvim_create_autocmd("BufReadPre", {
    group = group,
    callback = function(ev)
      if _is_large_by_size(ev.buf) then
        _apply(ev.buf)
      end
    end,
  })

  -- Long-line check needs the buffer contents, so it runs after the read.
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(ev)
      if not M.is_large(ev.buf) and _has_long_line(ev.buf) then
        _apply(ev.buf)
      end
    end,
  })

  -- Folding is window-local: apply it whenever a large buffer is shown.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(ev)
      if M.config.disable_folding and M.is_large(ev.buf) then
        vim.wo.foldenable = false
        vim.wo.foldmethod = "manual"
      end
    end,
  })
end

--- Remove the detection autocmds. Buffers already in large-file mode keep it.
function M.disable()
  pcall(vim.api.nvim_del_augroup_by_name, _AUGROUP)
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

---@param opts keystone.largefile.Config?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

  M.disable()
  if M.config.enabled then
    M.enable()
  end
end

return M
