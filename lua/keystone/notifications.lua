---@class keystone.notifications.Notification
---@field win_id integer
---@field buf_id integer
---@field height integer

---@class keystone.notifications.Config
---@field enabled boolean
---@field width integer
---@field border string|table
---@field timeout integer
---@field lsp_progress boolean
---@field lsp_progress_delay integer

---@class keystone.notifications.NotifyOpts
---@field title? string
---@field timeout? integer
---@field id? string|integer
---@field level? "info"|"warn"|"error"|"lsp"

local M = {}

---@type table<string|integer, keystone.notifications.Notification>
local _active = {}

---@type table<string|integer, boolean>
local _pending = {}

local _id_counter = 0
local _initialized = false
local _enabled = false
local _original_vim_notify = nil

local _hl_map = {
  info = "DiagnosticInfo",
  warn = "DiagnosticWarn",
  error = "DiagnosticError",
  lsp = "Normal",
}

local function _get_defaults()
  return {
    enabled = true,
    width = 36,
    border = "rounded",
    timeout = 1000,
    lsp_progress = true,
    lsp_progress_delay = 1000,
  }
end

M.config = _get_defaults()

---@return integer
local function _get_offset()
  return vim.o.cmdheight + (vim.o.laststatus ~= 0 and 1 or 0) + 2
end

local function _layout()
  local running_height = 0

  for _, n in pairs(_active) do
    if vim.api.nvim_win_is_valid(n.win_id) then
      local row = vim.o.lines - _get_offset() - running_height - n.height

      vim.api.nvim_win_set_config(n.win_id, {
        relative = "editor",
        row = row,
        col = vim.o.columns - M.config.width - 2,
      })

      running_height = running_height + n.height + 2
    end
  end
end

---@param id string|integer
local function _close(id)
  local n = _active[id]

  if not n then
    return
  end

  if vim.api.nvim_win_is_valid(n.win_id) then
    vim.api.nvim_win_close(n.win_id, true)
  end

  if vim.api.nvim_buf_is_valid(n.buf_id) then
    vim.api.nvim_buf_delete(n.buf_id, { force = true })
  end

  _active[id] = nil

  _layout()
end

---@param msg string|string[]
---@param opts? keystone.notifications.NotifyOpts
function M.notify(msg, opts)
  if not _enabled then
    local lines = type(msg) == "table" and msg or { msg }

    vim.api.nvim_echo({ { table.concat(lines, "\n"), "" } }, false, {})

    return
  end

  opts = opts or {}

  local id = opts.id or ("n_" .. _id_counter)

  if not opts.id then
    _id_counter = _id_counter + 1
  end

  local lines = type(msg) == "table" and msg or { msg }
  local level = opts.level or "info"

  local title = opts.title or "Notification"
  local title_hl = _hl_map[level] or "DiagnosticInfo"

  local n = _active[id]

  if not n then
    local buf = vim.api.nvim_create_buf(false, true)

    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = M.config.width,
      height = #lines,
      row = 0,
      col = 0,
      style = "minimal",
      border = M.config.border,
      title = {{ " " .. title .. " ", title_hl } },
      title_pos = "center",
      focusable = false,
      zindex = 100,
    })

    vim.api.nvim_set_option_value(
      "winhl",
      "NormalFloat:Normal,FloatBorder:Normal",
      { win = win }
    )

    n = {
      win_id = win,
      buf_id = buf,
      height = #lines,
    }

    _active[id] = n
  end

  vim.bo[n.buf_id].modifiable = true

  vim.api.nvim_buf_set_lines(n.buf_id, 0, -1, false, lines)

  vim.bo[n.buf_id].modifiable = false

  _layout()

  local timeout = opts.timeout or M.config.timeout

  if timeout > 0 then
    vim.defer_fn(function()
      _close(id)
    end, timeout)
  end

  return id
end

---@param msg string
---@param level? vim.log.levels
---@param opts? table
function M.ui_notify(msg, level, opts)
  if not _enabled then
    assert(_original_vim_notify)
    _original_vim_notify(msg, level, opts)
    return
  end

  opts = opts or {}

  local log_levels = {
    [1] = "info",
    [2] = "warn",
    [3] = "error",
    [4] = "error",
    [5] = "info",
  }

  if type(level) == "table" then
    opts = level
  elseif level then
    opts.level = log_levels[level] or "info"
  end

  return M.notify(msg, opts)
end

---@param progress lsp.ProgressParams
---@param ctx lsp.HandlerContext
local function _lsp_handler(_, progress, ctx)
  local client = vim.lsp.get_client_by_id(ctx.client_id)
  local val = progress.value

  if not client or not val then
    return
  end

  local token = progress.token

  local display_title = val.title
      and (client.name .. ": " .. val.title)
      or client.name

  local msg = (val.message or "")
      .. (val.percentage and (" [" .. val.percentage .. "%]") or "")

  if msg == "" and val.kind ~= "end" then
    msg = "..."
  end

  if val.kind == "begin" then
    _pending[token] = true
    vim.defer_fn(function()
      if not _pending[token] then
        return
      end
      _pending[token] = nil
      M.notify(msg, {
        id = token,
        title = display_title,
        level = "lsp",
        timeout = 0,
      })
    end, M.config.lsp_progress_delay)
  elseif val.kind == "report" then
    if _pending[token] then
      return
    end
    M.notify(msg, {
      id = token,
      title = display_title,
      level = "lsp",
      timeout = 0,
    })
  elseif val.kind == "end" then
    if _pending[token] then
      _pending[token] = nil
      return
    end
    M.notify(val.message or "Complete", {
      id = token,
      title = display_title,
      level = "lsp",
      timeout = 1500,
    })
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
    vim.notify = M.ui_notify

    if M.config.lsp_progress then
      local prev = vim.lsp.handlers["$/progress"]

      vim.lsp.handlers["$/progress"] = function(err, prog, ctx)
        if _enabled then
          _lsp_handler(err, prog, ctx)
        end

        if prev then
          prev(err, prog, ctx)
        end
      end
    end
  end
end

function M.disable()
  _enabled = false
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", _get_defaults(), opts or {})

  if M.config.enabled then
    M.enable()
  else
    M.disable()
  end
end

return M
