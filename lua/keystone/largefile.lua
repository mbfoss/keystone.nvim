local M = {}

-- ---------------------------------------------------------------------------
-- Large file handling
--
-- Opening a large file is slow mostly because of work Neovim and plugins do
-- *eagerly* on read: treesitter parsing, LSP attach, ftplugins, syntax
-- highlighting, plus swap/undo bookkeeping.
--
-- The reliable way to suppress the attach-on-read machinery is to *prevent* it,
-- not to tear it down afterwards: treesitter, LSP and ftplugins all hang off
-- `FileType` autocmds keyed on the file's real filetype. So we detect a large
-- file during filetype detection and give it a sentinel_ft filetype
-- (`config.filetype`, default "bigfile") instead of its real one. None of those
-- `FileType` handlers ever match, so nothing attaches in the first place --
-- deterministically, with no scheduled detach race.
--
-- A `FileType <sentinel_ft>` autocmd then applies the buffer-local tweaks and,
-- optionally, restores cheap regex syntax for the detected real filetype.
--
-- A file is "large" when it exceeds `size_threshold` bytes.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

---@class keystone.largefile.Config
---@field enabled boolean? master switch; when false detection is inert
---@field size_threshold integer? byte size above which a file is treated as large
---@field filetype string? sentinel_ft filetype used to suppress treesitter/LSP/ftplugins
---@field keep_syntax boolean? restore regex syntax for the detected real filetype
---@field disable_folding boolean? set `foldmethod=manual` and open all folds
---@field disable_swapfile boolean? clear `swapfile` for the buffer
---@field disable_undofile boolean? clear `undofile` (and shorten undolevels)
---@field disable_matchparen boolean? turn off the matchparen plugin while a large buffer is open
---@field undolevels integer? `undolevels` to use when `disable_undofile` is set
---@field synmaxcol integer? `synmaxcol` to clamp to (caps per-line syntax cost)
---@field notify boolean? emit a message when a buffer is opened in fast mode

---@return keystone.largefile.Config
local function _get_default_config()
  ---@type keystone.largefile.Config
  return {
    enabled            = true,
    size_threshold     = 1.5 * 1024 * 1024,  -- 1.5 MiB
    filetype           = "bigfile",
    keep_syntax        = false,
    disable_folding    = true,
    disable_swapfile   = true,
    disable_undofile   = false,
    disable_matchparen = true,
    undolevels         = -1,
    synmaxcol          = 256,
    notify             = true,
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

-- Whether detection is live. The `vim.filetype.add` hook is global and cannot be
-- unregistered, so `disable` flips this instead and the hook bails on false.
local _enabled = false

-- ---------------------------------------------------------------------------
-- Detection
-- ---------------------------------------------------------------------------

--- Byte size of `path`, or 0 when it cannot be stat'd.
---@param path string?
---@return integer
local function _stat_size(path)
  if not path or path == "" then return 0 end
  local stat = vim.loop.fs_stat(path)
  return stat and stat.size or 0
end

--- `vim.filetype.add` hook. Returns the sentinel_ft filetype for large files so
--- the real-filetype `FileType` handlers (treesitter/LSP/ftplugins) never fire;
--- returns nil for everything else so normal detection proceeds.
---@param path string?
---@param bufnr integer
---@return string?
local function _detect(path, bufnr)
  if not _enabled then return nil end

  local sentinel_ft = M.config.filetype
  -- Guard against re-entry: when the buffer already carries the sentinel_ft,
  -- `vim.filetype.match` is being used to resolve the *real* filetype.
  if vim.bo[bufnr].filetype == sentinel_ft then return nil end

  local threshold = M.config.size_threshold
  if threshold and threshold > 0 and _stat_size(path) > threshold then
    return sentinel_ft
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Application
-- ---------------------------------------------------------------------------

--- Apply fast-mode buffer-local options. Idempotent via the buffer flag, so the
--- `FileType` handler and `M.apply` can both call it. Treesitter/LSP/ftplugins
--- are not touched here: the sentinel_ft filetype keeps them from ever attaching.
---@param bufnr integer
local function _apply(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr][_BUF_FLAG] then return end
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

  if cfg.disable_matchparen and vim.g.loaded_matchparen == 1 then
    -- matchparen is global (no buffer-local form); turning it off is the
    -- cheapest correct way to keep it from scanning this buffer.
    vim.cmd("NoMatchParen")
  end

  -- Syntax: either restore cheap regex highlighting for the real filetype (clamped by
  -- synmaxcol) or leave it off. Deferred so it runs after the read settles, when
  -- `vim.filetype.match` re-resolves the real ft (the sentinel_ft guard lets it fall through).
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if cfg.keep_syntax then
      vim.bo[bufnr].syntax = vim.filetype.match({ buf = bufnr }) or ""
    else
      vim.bo[bufnr].syntax = "off"
    end
  end)

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

--- True when `bufnr` (defaults to current) is in fast mode.
---@param bufnr integer?
---@return boolean
function M.is_large(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return vim.b[bufnr][_BUF_FLAG] == true
end

--- Force `bufnr` (defaults to current) into fast mode regardless of size by
--- setting the sentinel_ft filetype and applying the tweaks. Best used before the
--- buffer is read; treesitter/LSP that already attached to an open buffer are
--- left as-is.
---@param bufnr integer?
function M.apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= M.config.filetype then
    vim.bo[bufnr].filetype = M.config.filetype
  end
  _apply(bufnr)
end

--- Activate detection.
function M.enable()
  _enabled = true

  -- Global, registered once. `[".*"]` runs for every file; the hook returns nil for
  -- non-large files so normal detection is unaffected. A high priority ensures it runs
  -- before extension/pattern matches that would otherwise short-circuit known types.
  vim.filetype.add({
    pattern = {
      [".*"] = { _detect, { priority = 200 } },
    },
  })

  local group = vim.api.nvim_create_augroup(_AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = M.config.filetype,
    callback = function(ev)
      _apply(ev.buf)
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

--- Deactivate detection. Buffers already in fast mode keep it.
function M.disable()
  _enabled = false
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
