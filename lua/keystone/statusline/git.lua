---Git branch section provider.
---
---Resolves the current branch itself via `git rev-parse` (no dependency on
---gitsigns or any other plugin), caching the result per buffer and refreshing on
---buffer/focus/directory changes and after writes. Detached HEAD renders as the
---short commit hash.
local M          = {}

local spawn      = require("keystone.util.spawn")
local throttle   = require("keystone.util.throttle")

local _AUGROUP   = "keystone_statusline_git"

-- [bufnr] = branch string ("" when the buffer is not in a work tree / unknown)
local _branch    = {}
-- called whenever a cached branch changes, so the statusline can redraw
local _on_change = nil

---@type table<string, vim.api.keyset.highlight>
M.highlights     = {
  KeystoneSLGit = { link = "" },
}

---@param bufnr integer
---@return string directory used to resolve the buffer's repository
local function _dir_for_buf(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" then
    return vim.fn.fnamemodify(name, ":p:h")
  end
  return vim.uv.cwd() or "."
end

---@param bufnr integer
---@param branch string
local function _set_branch(bufnr, branch)
  if _branch[bufnr] == branch then return end
  _branch[bufnr] = branch
  if _on_change then _on_change() end
end

---Run `git <args>` in `dir`, returning trimmed stdout (or nil on failure).
---@param dir  string
---@param args string[]
---@param cb   fun(out: string?)
local function _git(dir, args, cb)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local out = {}
  local ok = pcall(spawn, cmd, {
    cwd = dir,
    stdout = function(data) out[#out + 1] = data end,
  }, function(code)
    cb(code == 0 and (table.concat(out):gsub("%s+", "")) or nil)
  end)
  if not ok then cb(nil) end
end

---@param bufnr integer
local function _refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  if vim.bo[bufnr].buftype ~= "" then
    _set_branch(bufnr, "")
    return
  end
  local dir = _dir_for_buf(bufnr)
  _git(dir, { "rev-parse", "--abbrev-ref", "HEAD" }, function(branch)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not branch or branch == "" then
      _set_branch(bufnr, "")
    elseif branch == "HEAD" then
      -- detached HEAD — fall back to the short commit hash
      _git(dir, { "rev-parse", "--short", "HEAD" }, function(sha)
        if vim.api.nvim_buf_is_valid(bufnr) then
          _set_branch(bufnr, (sha and sha ~= "") and sha or "")
        end
      end)
    else
      _set_branch(bufnr, branch)
    end
  end)
end

---@param bufnr integer
---@return string
function M.render(bufnr)
  local branch = _branch[bufnr]
  if not branch or branch == "" then return "" end
  return "%#KeystoneSLGit# 󰘬 " .. branch:gsub("%%", "%%%%") .. " %*"
end

---@param on_change fun() called whenever a cached branch changes
function M.enable(on_change)
  _on_change = on_change
  local group = vim.api.nvim_create_augroup(_AUGROUP, { clear = true })

  local refresh_current = throttle.debounce_wrap(150, function()
    _refresh(vim.api.nvim_get_current_buf())
  end)

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "FocusGained", "DirChanged" }, {
    group = group,
    callback = refresh_current,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args) _branch[args.buf] = nil end,
  })

  _refresh(vim.api.nvim_get_current_buf())
end

function M.disable()
  _on_change = nil
  vim.api.nvim_del_augroup_by_name(_AUGROUP)
  _branch = {}
end

return M
