local M = {}

-- ---------------------------------------------------------------------------
-- keystone
--
-- Every feature module (`keystone.tweaks`, `keystone.largefile`, ...) is
-- self-contained and can be required and `setup()` directly. This module is an
-- optional convenience for people who prefer a single entry point:
--
--   require("keystone").setup({
--     tweaks    = { highlight_on_yank = false },  -- table -> module opts
--     largefile = true,                           -- true  -> module defaults
--     notify    = false,                          -- false -> skip (default)
--   })
--
-- It is opt-in: a module is configured only when its key is present and not
-- `false`. Modules you do not mention are left untouched, so this never enables
-- anything implicitly.
-- ---------------------------------------------------------------------------

-- Configurable modules, in setup order. Each names a `keystone.<name>` module
-- that exposes `setup(opts)`.
---@type string[]
local _MODULES = {
  "notify",
  "tweaks",
  "largefile",
  "animate",
  "bookmarks",
  "clue",
  "completion",
  "diff",
  "explore",
  "filetree",
  "lspconfig",
  "pick",
  "statusline",
  "tsconfig",
  "unsaved",
}

---@type table<string, true>
local _KNOWN = {}
for _, name in ipairs(_MODULES) do _KNOWN[name] = true end

--- Configure keystone modules from a single table. Each key is a module name;
--- its value is the module's `setup` opts (`true` for defaults, `false`/absent
--- to skip).
---@param opts table<string, table|boolean>?
function M.setup(opts)
  opts = opts or {}

  for name in pairs(opts) do
    if not _KNOWN[name] then
      vim.notify(("keystone.setup: unknown module %q"):format(name), vim.log.levels.WARN)
    end
  end

  for _, name in ipairs(_MODULES) do
    local value = opts[name]
    if value ~= nil and value ~= false then
      require("keystone." .. name).setup(value == true and {} or value)
    end
  end
end

return M
