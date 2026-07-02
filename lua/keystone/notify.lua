local common = require "keystone.tk.timer"
---@class keystone.notify.Notification
---@field win_id integer
---@field buf_id integer
---@field height integer
---@field width integer
---@field timer uv.uv_timer_t?

---@class keystone.notify.Config
---@field enabled boolean
---@field width number fraction of the editor width (0-1)
---@field border string|table
---@field timeout integer
---@field lsp_progress boolean
---@field lsp_progress_delay integer
---@field history_limit integer

---@class keystone.notify.NotifyOpts
---@field title? string
---@field timeout? integer
---@field id? string|integer
---@field level? "info"|"warn"|"error"|"lsp"

---@class keystone.notify.HistoryEntry
---@field id string|integer
---@field title string
---@field level "info"|"warn"|"error"|"lsp"
---@field message string[]
---@field timestamp integer

local M = {}

---@type table<string|integer, keystone.notify.Notification>
local _active = {}

---@type (string|integer)[]
local _order = {}

---@type table<string|integer,  {timer: uv.uv_timer_t?,msg: string, title: string}>
local _pending_lsp_notify = {}

---@type keystone.notify.HistoryEntry[]
local _history = {}

local _id_counter = 0
local _initialized = false
local _enabled = false
local _original_vim_notify = nil
local _LSP_AUGROUP = "keystone_notify_lsp"
local _layout_scheduled = false

local _hl_map = {
  info = "DiagnosticInfo",
  warn = "DiagnosticWarn",
  error = "DiagnosticError",
  lsp = "Normal",
}

local _icon_map = {
  info = "󰋽",
  warn = "󰀪",
  error = "󰅚",
  lsp = "󰒓",
}

local _log_level_map = {
  [vim.log.levels.INFO] = "info",
  [vim.log.levels.WARN] = "warn",
  [vim.log.levels.ERROR] = "error",
}

local function _get_defaults()
  return {
    enabled = true,
    width = 0.3,
    border = "rounded",
    timeout = 3000,
    lsp_progress = false,
    lsp_progress_delay = 1000, -- this avoids progress notification for short updates
    history_limit = 100,
  }
end

M.config = _get_defaults()

---@return integer
local function _get_offset()
  return vim.o.cmdheight + (vim.o.laststatus ~= 0 and 1 or 0) + 2
end

---@param lines string[]
---@param title string
---@return integer
local function _get_width(lines, title)
  local max_width = math.max(1, math.floor(vim.o.columns * M.config.width))
  local content = vim.fn.strdisplaywidth(title)
  for _, line in ipairs(lines) do
    content = math.max(content, vim.fn.strdisplaywidth(line))
  end
  return math.min(content, max_width)
end

---@param entry keystone.notify.HistoryEntry
local function _push_history(entry)
  if entry.level == "lsp" then
    return
  end

  table.insert(_history, entry)
  local limit = M.config.history_limit
  if #_history > limit then
    table.remove(_history, 1)
  end
end

local function _layout()
  if vim.v.exiting ~= vim.NIL then return end
  local running_height = 0
  for _, id in ipairs(_order) do
    local n = _active[id]
    if n and vim.api.nvim_win_is_valid(n.win_id) then
      local row = vim.o.lines - _get_offset() - running_height - n.height

      vim.api.nvim_win_set_config(n.win_id, {
        relative = "editor",
        width = n.width,
        row = row,
        col = vim.o.columns - n.width - 2,
      })

      running_height = running_height + n.height + 2
    end
  end
end

local function _schedule_layout()
  if vim.v.exiting ~= vim.NIL then return end
  if _layout_scheduled then return end

  _layout_scheduled = true

  vim.schedule(function()
    _layout_scheduled = false
    _layout()
  end)
end

---@param id string|integer
local function _close(id)
  local n = _active[id]

  if not n then
    return
  end

  if n.timer then
    common.stop_and_close_timer(n.timer)
    n.timer = nil
  end

  if vim.api.nvim_win_is_valid(n.win_id) then
    vim.api.nvim_win_close(n.win_id, true)
  end

  if vim.api.nvim_buf_is_valid(n.buf_id) then
    vim.api.nvim_buf_delete(n.buf_id, { force = true })
  end

  _active[id] = nil

  for i, oid in ipairs(_order) do
    if oid == id then
      table.remove(_order, i)
      break
    end
  end

  _schedule_layout()
end


---@param msg string|string[]
---@param opts? keystone.notify.NotifyOpts
local function _notify(msg, opts)
  if vim.v.exiting ~= vim.NIL then return end

  ---@diagnostic disable-next-line: param-type-mismatch
  local lines = type(msg) == "table" and msg or vim.split(tostring(msg), "\n")

  if not _enabled then
    vim.api.nvim_echo({ { table.concat(lines, "\n"), "" } }, false, {})
    return
  end

  opts = opts or {}

  local id = opts.id or ("n_" .. _id_counter)
  if not opts.id then
    _id_counter = _id_counter + 1
  end

  local level = opts.level or "info"
  local icon = _icon_map[level]
  local title = " " .. (opts.title or icon or "Notification") .. " "
  local title_hl = _hl_map[level] or "DiagnosticInfo"

  _push_history({
    id = id,
    title = title,
    level = level,
    message = vim.deepcopy(lines),
    timestamp = vim.uv.now(),
  })

  local width = _get_width(lines, title)
  local n = _active[id]

  if not n then
    local buf = vim.api.nvim_create_buf(false, true)

    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = width,
      height = #lines,
      row = 0,
      col = 0,
      style = "minimal",
      border = M.config.border,
      title = { { title, title_hl } },
      title_pos = "center",
      focusable = false,
      zindex = 100,
    })

    vim.wo[win].wrap = false
    vim.wo[win].list = true

    vim.api.nvim_set_option_value(
      "winhl",
      "NormalFloat:Normal,FloatBorder:Normal",
      { win = win }
    )

    n = {
      win_id = win,
      buf_id = buf,
      height = #lines,
      width = width,
      level = level,
    }

    _active[id] = n
    table.insert(_order, id)
  else
    if n.timer then
      common.stop_and_close_timer(n.timer)
      n.timer = nil
    end
    n.height = #lines
    n.width = width
  end

  vim.bo[n.buf_id].modifiable = true

  vim.api.nvim_buf_set_lines(n.buf_id, 0, -1, false, lines)

  vim.bo[n.buf_id].modifiable = false

  _layout()

  local timeout = opts.timeout or M.config.timeout or 0
  if timeout > 0 then
    n.timer = vim.defer_fn(function()
      _close(id)
    end, timeout)
  end
  return id
end

---@param msg string|string[]
---@param opts? keystone.notify.NotifyOpts
function M.notify(msg, opts)
  vim.schedule(function()
    _notify(msg, opts)
  end)
end

---@param id string|integer
function M.close(id)
  local state = _pending_lsp_notify[id]
  if state then
    common.stop_and_close_timer(state.timer)
    _pending_lsp_notify[id] = nil
  end
  _close(id)
end

---@return keystone.notify.HistoryEntry[]
function M.history()
  return vim.deepcopy(_history)
end

function M.clear_history()
  _history = {}
end

---@param msg string
---@param level? vim.log.levels
---@param opts? table
local function _override(msg, level, opts)
  if not _enabled then
    assert(_original_vim_notify)
    _original_vim_notify(msg, level, opts)
    return
  end
  opts = opts or {}
  if type(level) == "table" then
    opts = level
  elseif level then
    opts.level = _log_level_map[level] or "info"
  end
  return M.notify(msg, opts)
end

---@param ev vim.api.keyset.create_autocmd.callback_args
local function _lsp_handler(ev)
  if not _enabled then return end
  local client = vim.lsp.get_client_by_id(ev.data.client_id)
  local params = ev.data.params
  local val    = params and params.value

  if not client or not val then
    return
  end

  local token = params.token

  local display_title = val.title
      and (client.name .. ": " .. val.title)
      or client.name

  local msg = (val.message or "") .. (val.percentage and (" [" .. val.percentage .. "%]") or "")

  if msg == "" and val.kind ~= "end" then
    msg = "..."
  end

  if val.kind == "begin" then
    local existing = _pending_lsp_notify[token]
    if existing then
      common.stop_and_close_timer(existing.timer)
    end
    local token_state = {
      msg = msg,
      title = display_title,
    }
    _pending_lsp_notify[token] = token_state
    token_state.timer = vim.defer_fn(function()
      local state = _pending_lsp_notify[token]
      if not state then return end
      _pending_lsp_notify[token] = nil
      M.notify(state.msg, {
        id = token,
        title = state.title,
        level = "lsp",
        timeout = 0,
      })
    end, M.config.lsp_progress_delay)
  elseif val.kind == "report" then
    local state = _pending_lsp_notify[token]
    if state then
      state.msg = msg
      state.title = display_title
      return
    end
    M.notify(msg, {
      id = token,
      title = display_title,
      level = "lsp",
      timeout = 0,
    })
  elseif val.kind == "end" then
    local state = _pending_lsp_notify[token]
    if state then
      common.stop_and_close_timer(state.timer)
      _pending_lsp_notify[token] = nil
    end
    if msg ~= "" then
      M.notify(msg, {
        id = token,
        title = display_title,
        level = "lsp",
      })
    else
      _close(token)
    end
    return
  end
end

function M.enable()
  if _enabled then
    return
  end

  _enabled = true

  if not _initialized then
    _initialized = true

    assert(vim.notify)
    _original_vim_notify = vim.notify
    vim.notify = _override
  end
end

function M.disable()
  _enabled = false
end

function M.enable_lsp_progress()
  M.config.lsp_progress = true
  vim.api.nvim_create_autocmd("LspProgress", {
    group = vim.api.nvim_create_augroup(_LSP_AUGROUP, { clear = true }),
    callback = _lsp_handler,
  })
end

function M.disable_lsp_progress()
  M.config.lsp_progress = false
  pcall(vim.api.nvim_del_augroup_by_name, _LSP_AUGROUP)
  for token, state in pairs(_pending_lsp_notify) do
    if state.timer then
      common.stop_and_close_timer(state.timer)
    end
    _pending_lsp_notify[token] = nil
    _close(token)
  end
end

function M.toggle_lsp_progress()
  if M.config.lsp_progress then
    M.disable_lsp_progress()
  else
    M.enable_lsp_progress()
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", _get_defaults(), opts or {})

  if M.config.enabled then
    M.enable()
  else
    M.disable()
  end

  if M.config.lsp_progress then
    M.enable_lsp_progress()
  end
end

return M
