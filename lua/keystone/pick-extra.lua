-- keystone/pick-extra: opt-in pickers that aren't part of the core set.
--
-- These are kept separate so they can be enabled independently of `keystone.pick`.
-- Calling `setup()` registers each one into the shared picker registry, after
-- which they behave exactly like a core picker (`:Pick <name>`); each picker
-- module is only `require`d the first time it is opened.

local M = {}

local pick = require("keystone.pick")

---@type table<string, fun(): keystone.PickerSpec?>
local _pickers = {
    git_diff    = function() return require("keystone.pick-extra.git_diff").spec() end,
    git_history = function() return require("keystone.pick-extra.git_history").spec() end,
    git_grep    = function() return require("keystone.pick-extra.git_grep").spec() end,
    parse_debug = function() return require("keystone.pick-extra.parse_debug").spec() end,
}

---@class keystone.pick_extra.Config
---@field only string[]?    -- register only these picker names
---@field except string[]?  -- register everything except these picker names

---Register the extra pickers into the core picker registry.
---@param opts keystone.pick_extra.Config?
function M.setup(opts)
    opts = opts or {}

    for name, spec_fn in pairs(_pickers) do
        local include = true
        if opts.only then
            include = vim.tbl_contains(opts.only, name)
        elseif opts.except then
            include = not vim.tbl_contains(opts.except, name)
        end
        if include then
            pick.register(name, spec_fn)
        end
    end
end

---@return string[]
function M.names()
    return vim.tbl_keys(_pickers)
end

return M
