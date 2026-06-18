-- Health check for the tsconfig module. Run with `:checkhealth keystone.tsconfig`.
local M = {}

local _h = vim.health

-- Distinct parser languages with a compiled parser on the runtimepath.
---@return string[]
local function _installed_parsers()
  local seen, names = {}, {}
  for _, f in ipairs(vim.api.nvim_get_runtime_file("parser/*.so", true)) do
    local name = vim.fn.fnamemodify(f, ":t:r")
    if not seen[name] then
      seen[name] = true
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

---@param lang string
---@param kind string
---@return boolean
local function _has_query(lang, kind)
  local ok, q = pcall(vim.treesitter.query.get, lang, kind)
  return ok and q ~= nil
end

function M.check()
  _h.start("keystone.tsconfig")

  -- API availability ---------------------------------------------------------
  if not (vim.treesitter and vim.treesitter.start) then
    _h.error("vim.treesitter.start missing; requires Neovim >= 0.10")
    return
  end
  _h.ok("treesitter API available")

  -- Module state -------------------------------------------------------------
  local tsconfig = require("keystone.tsconfig")
  if tsconfig.is_enabled() then
    _h.ok("enabled")
  else
    _h.warn("not enabled", { "call require('keystone.tsconfig').setup()" })
  end

  -- Parser / query coverage --------------------------------------------------
  -- A parser without its highlights query is the common failure: treesitter
  -- highlights nothing, so such buffers are left on regex.
  _h.start("keystone.tsconfig: parsers")
  local parsers = _installed_parsers()
  if #parsers == 0 then
    _h.warn("no parsers on runtimepath", { "install via nvim-treesitter or :packadd" })
    return
  end

  _h.info(("%d installed: %s"):format(#parsers, table.concat(parsers, ", ")))
  -- Only flag a query type the module actually uses: highlights gate the
  -- regex->treesitter swap, folds gate foldexpr. A disabled feature is not a fault.
  local cfg = tsconfig.config
  local missing = 0
  for _, lang in ipairs(parsers) do
    local no_hl = cfg.highlight and not _has_query(lang, "highlights")
    local no_fold = cfg.fold and not _has_query(lang, "folds")
    if no_hl then
      _h.warn(lang .. ": no highlights query", {
        "add queries/" .. lang .. "/highlights.scm to runtimepath",
      })
    end
    if no_fold then
      _h.warn(lang .. ": no folds query", {
        "add queries/" .. lang .. "/folds.scm to runtimepath",
      })
    end
    if no_hl or no_fold then
      missing = missing + 1
    else
      _h.ok(lang .. ": queries present")
    end
  end
  if missing == 0 then
    _h.ok("all parsers have required queries")
  end
end

return M
