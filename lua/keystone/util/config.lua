---@brief Keeping a module's live config table fresh.
---
---A module's `M.config` is read by `keystone.health` and captured at load time
---by its own submodules, so `setup()` must refill it rather than replace it.

local M = {}

---Overwrite `dst` from `src` key by key: a key `src` lacks is dropped, and a
---table on both sides recurses instead of being swapped in.
---@param dst table
---@param src table
local function _refill(dst, src)
    for k in pairs(dst) do
        if src[k] == nil then dst[k] = nil end
    end
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            _refill(dst[k], v)
        else
            dst[k] = v
        end
    end
end

---Merge `opts` over `defaults` into `live`, in place. `live` keeps its identity,
---and so does every table under it, so a submodule may capture it at its top.
---Merging over a fresh copy of the defaults means no key of an earlier
---`setup()` survives into a later one.
---@generic T: table
---@param live T       the module's live config table
---@param defaults T   the module's defaults, left untouched
---@param opts table?  the user's options
---@return T live
function M.apply(live, defaults, opts)
    _refill(live, vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {}))
    return live
end

return M
