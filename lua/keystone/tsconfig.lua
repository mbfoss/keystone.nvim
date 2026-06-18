local M = {}

local _usercmd = require("keystone.util.usercmd")

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

---@class keystone.tsconfig.Config
---@field enabled boolean
---@field highlight boolean start treesitter highlighting (replacing regex syntax) on `FileType` for buffers whose language has a parser. Core only does this for its ~7 bundled languages.
---@field fold boolean set `foldmethod=expr` + `foldexpr=v:lua.vim.treesitter.foldexpr()` for parser-backed buffers
---@field fold_open boolean when `fold` is on, start with all folds open (`foldlevel=99`) so opening a file does not collapse it
---@field aliases table<string, string> map a filetype to the parser language to use for it, e.g. `{ typescriptreact = "tsx" }` (passed to `vim.treesitter.language.register`)
---@field disable string[]|fun(lang:string, bufnr:integer):boolean languages to skip; a list of language names or a predicate returning true to skip
---@field on_attach? fun(bufnr:integer, lang:string) extra per-buffer setup hook, run after highlighting starts

---@return keystone.tsconfig.Config
local function _get_default_config()
  ---@type keystone.tsconfig.Config
  return {
    enabled   = true,
    highlight = true,
    fold      = true,
    fold_open = true,
    aliases   = {},
    disable   = {},
    on_attach = nil,
  }
end

---@type keystone.tsconfig.Config
M.config = _get_default_config()

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local _enabled = false
local _group = "keystone_tsconfig"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function _has_api()
  return vim.treesitter ~= nil and vim.treesitter.start ~= nil
end

-- Resolve the treesitter language for a buffer from its filetype, honouring
-- any registered aliases (e.g. filetype `typescriptreact` -> parser `tsx`).
---@param bufnr integer
---@return string? lang nil when the buffer has no filetype
local function _lang_for(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft == "" then return nil end
  return vim.treesitter.language.get_lang(ft) or ft
end

-- True when a compiled parser for `lang` exists on the runtimepath. This is a
-- side-effect-free check: it does not load the parser the way `get_parser` would.
---@param lang string?
---@return boolean
local function _parser_available(lang)
  if not lang then return false end
  return #vim.api.nvim_get_runtime_file("parser/" .. lang .. ".*", false) > 0
end

---@param lang string
---@param bufnr integer
---@return boolean
local function _is_disabled(lang, bufnr)
  local d = M.config.disable
  if type(d) == "function" then return d(lang, bufnr) and true or false end
  return vim.tbl_contains(d, lang)
end

-- Set treesitter folding on the *current* window/buffer. Uses the
-- buffer-local-window form (`vim.wo[0][0]`) so the options don't leak to other
-- buffers shown in the same window.
local function _apply_fold()
  vim.wo[0][0].foldmethod = "expr"
  vim.wo[0][0].foldexpr = "v:lua.vim.treesitter.foldexpr()"
  if M.config.fold_open then
    vim.wo[0][0].foldlevel = 99
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Start treesitter for a buffer: highlighting, folds and the on_attach hook,
-- subject to config. No-op when the buffer's language has no parser installed.
---@param bufnr? integer defaults to the current buffer
function M.attach(bufnr)
  if not _has_api() then return end
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end

  local lang = _lang_for(bufnr)
  if not _parser_available(lang) then return end
  ---@cast lang string
  if _is_disabled(lang, bufnr) then return end

  if M.config.highlight then
    -- pcall: a parser file can exist but fail to load (ABI mismatch); don't
    -- let one bad parser break the FileType autocmd.
    pcall(vim.treesitter.start, bufnr, lang)
  end

  -- Fold options are window-local, so only apply them when this buffer is the
  -- one in the current window. The FileType autocmd always satisfies this.
  if M.config.fold and vim.api.nvim_get_current_buf() == bufnr then
    _apply_fold()
  end

  if M.config.on_attach then
    M.config.on_attach(bufnr, lang)
  end
end

-- Stop treesitter highlighting for a buffer (falls back to regex syntax).
---@param bufnr? integer defaults to the current buffer
function M.stop(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pcall(vim.treesitter.stop, bufnr)
end

function M.enable()
  if _enabled then return end
  if not _has_api() then
    vim.notify(
      "[keystone.nvim] tsconfig module requires Neovim >= 0.10 (vim.treesitter.start). Module disabled.",
      vim.log.levels.WARN
    )
    return
  end
  _enabled = true

  -- Register filetype -> parser aliases so `get_lang`/`start` resolve correctly.
  for ft, lang in pairs(M.config.aliases or {}) do
    pcall(vim.treesitter.language.register, lang, ft)
  end

  local group = vim.api.nvim_create_augroup(_group, { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(args)
      if not _enabled then return end
      M.attach(args.buf)
    end,
  })

  -- Attach buffers that are already displayed. Running inside `win_call` makes
  -- each window current in turn, so window-local fold options land correctly.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_win_call(win, function() M.attach(buf) end)
    end
  end
end

function M.disable()
  if not _enabled then return end
  _enabled = false
  pcall(vim.api.nvim_del_augroup_by_name, _group)
end

-- Print a short summary: installed parsers, and this buffer's language + which
-- highlighter (treesitter vs. regex) is currently driving it.
function M.info()
  local buf = vim.api.nvim_get_current_buf()
  local ft = vim.bo[buf].filetype
  local lang = _lang_for(buf)
  local active = vim.treesitter.highlighter.active[buf] ~= nil

  local seen, names = {}, {}
  for _, f in ipairs(vim.api.nvim_get_runtime_file("parser/*.so", true)) do
    local name = vim.fn.fnamemodify(f, ":t:r")
    if not seen[name] then
      seen[name] = true
      table.insert(names, name)
    end
  end
  table.sort(names)

  local lines = {
    "keystone.tsconfig",
    "  this buffer: ft=" .. (ft ~= "" and ft or "none")
      .. " lang=" .. (lang or "none")
      .. " highlight=" .. (active and "treesitter" or (lang and _parser_available(lang) and "regex (parser available)" or "regex/none")),
    "  installed parsers (" .. #names .. "): " .. (next(names) and table.concat(names, ", ") or "none"),
  }
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- User command
-- ---------------------------------------------------------------------------

local _subcommands = {
  info    = function() M.info() end,
  start   = function() M.attach() end,
  stop    = function() M.stop() end,
  restart = function() M.stop(); M.attach() end,
  enable  = function() M.enable() end,
  disable = function() M.disable() end,
}

---@param _cmd string
---@param args string[]
local function _run(_cmd, args)
  local sub = args[1] or "info"
  local fn = _subcommands[sub]
  if not fn then
    vim.notify("[keystone.nvim] :Treesitter unknown subcommand '" .. sub .. "'", vim.log.levels.ERROR)
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

---@param opts keystone.tsconfig.Config?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

  _usercmd.register_user_cmd("Treesitter", _run, {
    desc = "keystone treesitter control",
    subcommand_fn = _complete,
  })

  if M.config.enabled then
    M.enable()
  else
    M.disable()
  end
end

return M
