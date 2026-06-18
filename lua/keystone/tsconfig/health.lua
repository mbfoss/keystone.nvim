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
  local missing = 0
  for _, lang in ipairs(parsers) do
    if _has_query(lang, "highlights") then
      _h.ok(lang .. ": highlights query present")
    else
      missing = missing + 1
      _h.warn(lang .. ": no highlights query", {
        "add queries/" .. lang .. "/highlights.scm to runtimepath",
      })
    end
  end
  if missing == 0 then
    _h.ok("all parsers have highlights queries")
  end
end

return M
