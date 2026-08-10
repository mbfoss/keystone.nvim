local M = {}

-- ---------------------------------------------------------------------------
-- Buffer deletion that leaves the window layout alone
--
-- `:bdelete` closes every window the buffer happens to be displayed in, so
-- deleting a buffer from a split layout collapses that layout. What people
-- usually want is the buffer gone and the windows left exactly where they are.
--
-- The fix is to stop the buffer being the last thing holding those windows
-- open: before deleting, every window showing the buffer is pointed at a
-- replacement (that window's alternate file, else the most recently used other
-- listed buffer, else one shared empty scratch buffer). Only then is the buffer
-- deleted, at which point no window depends on it and nothing collapses.
--
-- Everything else here builds on that single primitive: `delete_others`,
-- `delete_hidden` and `delete_all` are just buffer selections handed to it,
-- filtered by the `ignore_*` rules so a sweep does not take the terminal, the
-- floating preview or the `.env` file with it.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

-- The `ignore_*` options describe buffers a *bulk* selection must leave alone
-- (`others`, `hidden`, `all`, `delete_many`). They never block an explicitly
-- named buffer: `:Bdelete` on the buffer in front of you, or `M.delete(bufnr)`,
-- deletes what you pointed at -- you already said which one you meant.
---@class keystone.bufdelete.Config
---@field enabled boolean? master switch; when false `setup` registers nothing
---@field ignore_floats boolean? keep buffers that are displayed in a floating window
---@field ignore_file_types string[]? filetypes to keep
---@field ignore_filename_patterns string[]? Lua patterns matched against the full buffer name; a match is kept
---@field ignore_alt_file boolean? keep the current window's alternate file (`#`)
---@field ignore_special_buffers boolean? keep buffers with a non-empty `buftype` (help, quickfix, terminal, ...)

---@return keystone.bufdelete.Config
local function _get_default_config()
  ---@type keystone.bufdelete.Config
  return {
    enabled                     = true,
    ignore_floats               = true,
    ignore_file_types           = {},
    ignore_filename_patterns    = {},
    ignore_alt_file             = false,
    ignore_special_buffers      = true, -- buffers with special buftype
  }
end

---@type keystone.bufdelete.Config
M.config = _get_default_config()

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

---@class keystone.bufdelete.Opts
---@field force boolean? delete a modified or terminal buffer anyway, discarding unsaved changes
---@field wipe boolean? use `:bwipeout` semantics instead of `:bdelete`
---@field ignore boolean? apply the `ignore_*` rules (default true for bulk, false for a named buffer)

---@param opts keystone.bufdelete.Opts?
---@return boolean force, boolean wipe
local function _resolve(opts)
  opts = opts or {}
  return opts.force == true, opts.wipe == true
end

-- ---------------------------------------------------------------------------
-- Buffer / window queries
-- ---------------------------------------------------------------------------

---@param bufnr integer
---@return boolean
local function _is_listed(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buflisted
end

--- A buffer a window can be left sitting on: an ordinary file buffer. Terminals,
--- help, quickfix and the rest are listed often enough to be picked as a
--- replacement, and landing a window on one after a delete is never what was
--- meant -- the window should show a file, or nothing.
---@param bufnr integer
---@return boolean
local function _is_normal(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == ""
end

--- Every window showing `bufnr`, across all tabpages (`nvim_list_wins` only
--- covers the current one).
---@param bufnr integer
---@return integer[]
local function _windows_showing(bufnr)
  local wins = {}
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
        table.insert(wins, win)
      end
    end
  end
  return wins
end

--- Listed buffers, most recently used first.
---@return integer[]
function M.listed()
  local infos = vim.fn.getbufinfo({ buflisted = 1 })
  table.sort(infos, function(a, b) return a.lastused > b.lastused end)

  local out = {}
  for _, info in ipairs(infos) do
    table.insert(out, info.bufnr)
  end
  return out
end

--- Listed buffers that no window currently shows.
---@return integer[]
function M.hidden()
  local out = {}
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    if #info.windows == 0 then
      table.insert(out, info.bufnr)
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Ignore rules
-- ---------------------------------------------------------------------------

---@param bufnr integer
---@return boolean
local function _in_float(bufnr)
  for _, win in ipairs(_windows_showing(bufnr)) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then return true end
  end
  return false
end

---@param bufnr integer
---@return boolean
local function _is_alt_file(bufnr)
  return bufnr == vim.fn.bufnr("#")
end

---@param bufnr integer
---@return boolean
local function _matches_pattern(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  for _, pattern in ipairs(M.config.ignore_filename_patterns or {}) do
    if name:match(pattern) then return true end
  end
  return false
end

--- Why a bulk selection keeps `bufnr`, or nil when it may go. Returning the
--- reason rather than a boolean is what lets the caller say *which* rule kept a
--- buffer instead of silently doing less than asked.
---@param bufnr integer
---@return string?
function M.ignore_reason(bufnr)
  local cfg = M.config

  if cfg.ignore_special_buffers and vim.bo[bufnr].buftype ~= "" then
    return ("special buffer (buftype=%s)"):format(vim.bo[bufnr].buftype)
  end
  if cfg.ignore_floats and _in_float(bufnr) then
    return "shown in a floating window"
  end
  if cfg.ignore_alt_file and _is_alt_file(bufnr) then
    return "alternate file"
  end
  if vim.tbl_contains(cfg.ignore_file_types or {}, vim.bo[bufnr].filetype) then
    return ("filetype %s"):format(vim.bo[bufnr].filetype)
  end
  if _matches_pattern(bufnr) then
    return "name matches an ignore pattern"
  end
  return nil
end

---@param bufnr integer
---@return boolean
function M.is_ignored(bufnr)
  return M.ignore_reason(bufnr) ~= nil
end

-- ---------------------------------------------------------------------------
-- Replacement buffers
-- ---------------------------------------------------------------------------

--- The empty scratch buffer handed to windows with nothing better to show. One
--- per delete call, shared by every such window, so emptying a layout of five
--- splits leaves one empty buffer rather than five.
---@param cache { bufnr: integer? }
---@return integer
local function _empty_buffer(cache)
  if cache.bufnr and vim.api.nvim_buf_is_valid(cache.bufnr) then
    return cache.bufnr
  end
  -- Listed and non-scratch: it stands in for a real buffer, so `:bnext` and the
  -- buffer list should see it exactly as `:enew` would.
  cache.bufnr = vim.api.nvim_create_buf(true, false)
  return cache.bufnr
end

--- What `win` should show once the buffer it displays is gone: its own
--- alternate file if that survives, else the most recently used listed buffer
--- that is not itself doomed, else a shared empty buffer. Every candidate is a
--- normal file buffer -- a window is never handed a terminal, help or quickfix
--- buffer it did not ask for.
---@param win integer
---@param doomed table<integer, true> buffers about to be deleted
---@param cache { bufnr: integer? }
---@return integer
local function _replacement_for(win, doomed, cache)
  ---@param bufnr integer?
  ---@return boolean
  local function usable(bufnr)
    return bufnr ~= nil and bufnr > 0 and not doomed[bufnr]
        and _is_listed(bufnr) and _is_normal(bufnr)
  end

  -- `#` is per-window, so this is the buffer *this* window would jump back to.
  local alt = vim.api.nvim_win_call(win, function() return vim.fn.bufnr("#") end)
  if usable(alt) then return alt end

  for _, bufnr in ipairs(M.listed()) do
    if usable(bufnr) then return bufnr end
  end

  return _empty_buffer(cache)
end

--- Point every window showing `bufnr` at something else, so deleting it cannot
--- take a window down with it.
---@param bufnr integer
---@param doomed table<integer, true>
---@param cache { bufnr: integer? }
local function _detach_windows(bufnr, doomed, cache)
  for _, win in ipairs(_windows_showing(bufnr)) do
    local is_float = vim.api.nvim_win_get_config(win).relative ~= ""
    -- A float is not part of the layout there is anything to preserve, so when
    -- its buffer is deleted anyway -- an explicit `:Bdelete`, or `ignore_floats`
    -- turned off -- closing it is the honest outcome. Unless it is all that is
    -- left: closing the last window would end the tabpage, so it takes a
    -- replacement buffer like any other window.
    local only_win = #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win)) == 1
    if is_float and not only_win then
      vim.api.nvim_win_close(win, false)
    else
      vim.api.nvim_win_set_buf(win, _replacement_for(win, doomed, cache))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Deletion
-- ---------------------------------------------------------------------------

--- Why `bufnr` cannot be deleted without `force`, or nil when it can.
---@param bufnr integer
---@return string?
local function _blocker(bufnr)
  if vim.bo[bufnr].modified then
    return "buffer has unsaved changes"
  end
  if vim.bo[bufnr].buftype == "terminal" then
    return "buffer is a terminal"
  end
  return nil
end

--- Delete `bufnr` itself, once nothing displays it any more. Both branches take
--- `force` from the same guarded value, so `:bdelete` and `:bwipeout` treat
--- unsaved changes identically.
---@param bufnr integer
---@param force boolean
---@param wipe boolean
local function _drop(bufnr, force, wipe)
  if wipe then
    -- `nvim_buf_delete` is `:bwipeout`; `:bdelete` only unlists, which is why
    -- the two paths are not the same call.
    vim.api.nvim_buf_delete(bufnr, { force = force })
  else
    vim.cmd.bdelete({ count = bufnr, bang = force })
  end
end

--- Swap the buffer out of its windows, then delete it -- and if the delete is
--- refused after all (a `BufUnload` autocmd, `'confirm'`, anything Neovim
--- objects to), put it straight back where it was. A modified buffer must never
--- end up deleted *or* hidden away off-screen because of a half-finished
--- operation.
---@param bufnr integer
---@param force boolean
---@param wipe boolean
---@param doomed table<integer, true>
---@param cache { bufnr: integer? }
---@return boolean deleted
local function _detach_and_drop(bufnr, force, wipe, doomed, cache)
  local wins = _windows_showing(bufnr)
  _detach_windows(bufnr, doomed, cache)

  -- The pcall is the rollback trigger: without it a refused delete would leave
  -- the buffer orphaned in no window at all.
  local ok, err = pcall(_drop, bufnr, force, wipe)
  if ok then return true end

  if vim.api.nvim_buf_is_valid(bufnr) then
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_buf(win, bufnr)
      end
    end
  end
  vim.notify(
    ("[keystone.bufdelete] could not delete %s: %s")
    :format(vim.fn.bufname(bufnr), tostring(err)),
    vim.log.levels.ERROR
  )
  return false
end

--- Delete a buffer without disturbing the window layout. This is the explicit
--- path: the `ignore_*` rules do not apply unless `opts.ignore` asks for them,
--- because naming a buffer already says which one you meant.
---@param bufnr integer? defaults to the current buffer
---@param opts keystone.bufdelete.Opts?
---@return boolean deleted
function M.delete(bufnr, opts)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not bufnr then return false end
  local force, wipe = _resolve(opts)

  if not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify(("[keystone.bufdelete] no such buffer: %d"):format(bufnr), vim.log.levels.WARN)
    return false
  end

  if opts and opts.ignore then
    local reason = M.ignore_reason(bufnr)
    if reason then
      vim.notify(
        ("[keystone.bufdelete] kept %s: %s"):format(vim.fn.bufname(bufnr), reason),
        vim.log.levels.INFO
      )
      return false
    end
  end

  if not force then
    local blocker = _blocker(bufnr)
    if blocker then
      vim.notify(
        ("[keystone.bufdelete] %s (add ! to force): %s")
        :format(blocker, vim.fn.bufname(bufnr)),
        vim.log.levels.WARN
      )
      return false
    end
  end

  return _detach_and_drop(bufnr, force, wipe, { [bufnr] = true }, {})
end

--- Delete several buffers as one operation, so a buffer on the way out is never
--- chosen as the replacement for another. This is the bulk path: the `ignore_*`
--- rules apply unless `opts.ignore` is explicitly false.
---@param bufnrs integer[]
---@param opts keystone.bufdelete.Opts?
---@return integer deleted count of buffers actually deleted
function M.delete_many(bufnrs, opts)
  local force, wipe = _resolve(opts)
  local apply_ignore = not (opts and opts.ignore == false)

  ---@type table<integer, true>
  local doomed = {}
  ---@type integer[]
  local targets = {}
  -- The two ways a buffer can be spared are counted apart because only one of
  -- them is about unsaved work, and only that one is worth a warning.
  local unsafe = 0
  local ignored = 0

  for _, bufnr in ipairs(bufnrs) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      if apply_ignore and M.is_ignored(bufnr) then
        ignored = ignored + 1
      elseif not force and _blocker(bufnr) then
        unsafe = unsafe + 1
      else
        doomed[bufnr] = true
        table.insert(targets, bufnr)
      end
    end
  end

  local cache = {}
  local deleted = 0
  for _, bufnr in ipairs(targets) do
    if _detach_and_drop(bufnr, force, wipe, doomed, cache) then
      deleted = deleted + 1
    end
  end

  if unsafe > 0 then
    vim.notify(
      ("[keystone.bufdelete] kept %d buffer(s) with unsaved changes or a running terminal (add ! to force)")
      :format(unsafe),
      vim.log.levels.WARN
    )
  end
  if ignored > 0 then
    vim.notify(
      ("[keystone.bufdelete] kept %d ignored buffer(s)"):format(ignored),
      vim.log.levels.INFO
    )
  end
  return deleted
end

--- Delete every listed buffer except the current one.
---@param opts keystone.bufdelete.Opts?
---@return integer deleted
function M.delete_others(opts)
  local keep = vim.api.nvim_get_current_buf()
  local targets = {}
  for _, bufnr in ipairs(M.listed()) do
    if bufnr ~= keep then table.insert(targets, bufnr) end
  end
  return M.delete_many(targets, opts)
end

--- Delete every listed buffer no window is showing.
---@param opts keystone.bufdelete.Opts?
---@return integer deleted
function M.delete_hidden(opts)
  return M.delete_many(M.hidden(), opts)
end

--- Delete every listed buffer. The layout survives: its windows end up on one
--- shared empty buffer.
---@param opts keystone.bufdelete.Opts?
---@return integer deleted
function M.delete_all(opts)
  return M.delete_many(M.listed(), opts)
end

-- ---------------------------------------------------------------------------
-- Commands
--
-- `:Bdelete` and `:Bwipeout` mirror the built-ins they are named after and take
-- the same argument. They differ only in the `wipe` flag they pass; the
-- unsaved-changes guard lives below that split, in `M.delete`/`M.delete_many`,
-- so neither command can discard an edit the other would have refused.
--
-- `:Bdeletehidden` and `:Bwipeouthidden` are the same pair over a fixed
-- selection: the buffers no window is showing. "No window" spans every tabpage,
-- not just the current one, so neither can pull a buffer out from under a window
-- you cannot see.
--
-- No command has an argument slot for keywords. What follows `:Bdelete` is
-- always a buffer name or a glob over buffer names; the `*hidden` pair takes
-- nothing at all. So a buffer called `all`, `hidden` or `-x` is nothing special
-- anywhere.
-- ---------------------------------------------------------------------------

--- Match `glob` against a buffer the way a user reading the command line would
--- expect: `*.lua` should match a full path, `src/*.lua` a path relative to the
--- cwd, so both spellings of the name are tried.
---@param bufnr integer
---@param glob string
---@return boolean
local function _matches_glob(bufnr, glob)
  local pattern = vim.fn.glob2regpat(glob)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local candidates = { name, vim.fn.fnamemodify(name, ":~:."), vim.fn.fnamemodify(name, ":t") }
  for _, candidate in ipairs(candidates) do
    if vim.fn.match(candidate, pattern) >= 0 then return true end
  end
  return false
end

--- Listed buffers whose name matches `glob`.
---@param glob string
---@return integer[]
function M.matching(glob)
  local out = {}
  for _, bufnr in ipairs(M.listed()) do
    if _matches_glob(bufnr, glob) then table.insert(out, bufnr) end
  end
  return out
end

--- Delete every listed buffer whose name matches `glob`. A set, so the
--- `ignore_*` rules apply.
---@param glob string
---@param opts keystone.bufdelete.Opts?
---@return integer deleted
function M.delete_matching(glob, opts)
  return M.delete_many(M.matching(glob), opts)
end

---@param arg string
---@return boolean
local function _has_wildcard(arg)
  return arg:find("[%*%?%[]") ~= nil
end

--- Completion for `:Bdelete`/`:Bwipeout`: buffer names, plus the glob that
--- means all of them.
---@param _ string
---@param rest string[]
---@return string[]
local function _complete_buffers(_, rest)
  if #rest > 0 then return {} end

  local out = { "*" }
  for _, bufnr in ipairs(M.listed()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" then
      table.insert(out, vim.fn.fnamemodify(name, ":~:."))
    end
  end
  return out
end

--- Body shared by `:Bdelete` and `:Bwipeout`: `wipe` is the only difference.
---@param wipe boolean
---@return keystone.util.usercmd.run_fn
local function _make_delete_command(wipe)
  return function(_, args, opts)
    local arg = args[1]
    ---@type keystone.bufdelete.Opts
    local call_opts = { force = opts.bang, wipe = wipe }

    -- A count targets that buffer number; without one the bare command means
    -- the current buffer.
    if arg == nil then
      M.delete(opts.count > 0 and opts.count or nil, call_opts)
      return
    end

    -- A glob selects a set, and a set goes through the `ignore_*` rules. A plain
    -- name is one buffer the user pointed at, matched the way `:bdelete {name}`
    -- matches, and is deleted as named.
    if _has_wildcard(arg) then
      local targets = M.matching(arg)
      if #targets == 0 then
        vim.notify("[keystone.bufdelete] no buffer matching: " .. arg, vim.log.levels.WARN)
        return
      end
      M.delete_many(targets, call_opts)
      return
    end

    local bufnr = vim.fn.bufnr(arg)
    if bufnr == -1 then
      vim.notify("[keystone.bufdelete] no buffer matching: " .. arg, vim.log.levels.WARN)
      return
    end
    M.delete(bufnr, call_opts)
  end
end

--- Body shared by `:Bdeletehidden` and `:Bwipeouthidden`: `wipe` is the only
--- difference, exactly as it is between `:Bdelete` and `:Bwipeout`.
---@param wipe boolean
---@return keystone.util.usercmd.run_fn
local function _make_hidden_command(wipe)
  return function(_, _args, opts)
    M.delete_hidden({ force = opts.bang, wipe = wipe })
  end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

--- Register `:Bdelete`/`:Bwipeout`: one buffer-name-or-glob argument, an
--- optional count, and `!` to force.
---@param name string
---@param wipe boolean
---@param desc string
local function _register_delete(name, wipe, desc)
  local run = _make_delete_command(wipe)
  vim.api.nvim_create_user_command(name, function(cmd_opts)
    require("keystone.util.usercmd").handle(cmd_opts, run)
  end, {
    nargs = "*",
    bang = true,
    count = true,
    desc = desc,
    complete = function(arg_lead, cmd_line, _)
      return require("keystone.util.usercmd").complete(arg_lead, cmd_line, _complete_buffers)
    end,
  })
end

--- Register `:Bdeletehidden`/`:Bwipeouthidden`: no argument, no count — the
--- selection is fixed — and `!` to force.
---@param name string
---@param wipe boolean
---@param desc string
local function _register_hidden(name, wipe, desc)
  local run = _make_hidden_command(wipe)
  vim.api.nvim_create_user_command(name, function(cmd_opts)
    require("keystone.util.usercmd").handle(cmd_opts, run)
  end, {
    nargs = 0,
    bang = true,
    desc = desc,
  })
end

---@param opts keystone.bufdelete.Config?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})
  if not M.config.enabled then return end

  _register_delete("Bdelete", false, "Delete buffers, keeping the window layout")
  _register_delete("Bwipeout", true, "Wipe out buffers, keeping the window layout")

  _register_hidden("Bdeletehidden", false, "Delete every buffer no window is showing")
  _register_hidden("Bwipeouthidden", true, "Wipe out every buffer no window is showing")
end

return M
