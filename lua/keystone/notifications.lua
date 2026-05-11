---@class keystone.lspprogress.Notification
---@field win_id integer
---@field buf_id integer

---@class keystone.lspprogress.Config
---@field enabled boolean
---@field width integer
---@field border string|table
---@field timeout integer

local M = {}

---@type table<string|integer, keystone.lspprogress.Notification>
local _active_notifications = {}

local _initialized = false
local _enabled = false

---@return keystone.lspprogress.Config
local function _get_default_config()
  return {
    enabled = true,
    width = 40,
    border = "rounded",
    timeout = 3000,
  }
end

---@type keystone.lspprogress.Config
M.config = _get_default_config()

---@return integer
local function _bottom_offset()
  local cmdheight = vim.o.cmdheight
  local laststatus = vim.o.laststatus
  local offset = cmdheight
  if laststatus ~= 0 then
    offset = offset + 1
  end
  return offset + 2
end


---@param token string|integer
---@param index integer
---@param height integer
local function _update_position(token, index, height)
  local notification = _active_notifications[token]
  if not notification then
    return
  end

  if not vim.api.nvim_win_is_valid(notification.win_id) then
    return
  end

  vim.api.nvim_win_set_config(notification.win_id, {
    relative = "editor",
    width = M.config.width,
    height = height,
    row = vim.o.lines - height - _bottom_offset() - (index * (height + 1)),
    col = vim.o.columns - M.config.width - 2,
  })
end

---@param token string|integer
---@param data table
---@param is_done boolean
local function _render_notification(token, data, is_done)
  local client = data.client or "LSP"
  local title = data.title or "Progress"
  local message = data.message or ""
  local percentage = data.percentage

  local lines = {
    string.format(" %s [%s]", client, title),
  }

  if percentage then
    table.insert(lines, string.format(" %d%%", percentage))
  end

  if message ~= "" then
    table.insert(lines, " " .. message)
  end

  if is_done then
    table.insert(lines, " Done")
  end

  local notification = _active_notifications[token]

  if not notification then
    local buf = vim.api.nvim_create_buf(false, true)

    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = M.config.width,
      height = #lines,
      row = 0,
      col = 0,
      style = "minimal",
      border = M.config.border,
      focusable = false,
      noautocmd = true,
      zindex = 100,
    })

    vim.api.nvim_set_option_value(
      "winhl",
      "NormalFloat:NormalFloat,FloatBorder:NormalFloat",
      { win = win }
    )

    notification = {
      win_id = win,
      buf_id = buf,
    }

    _active_notifications[token] = notification
  end

  if vim.api.nvim_buf_is_valid(notification.buf_id) then
    vim.bo[notification.buf_id].modifiable = true
    vim.api.nvim_buf_set_lines(notification.buf_id, 0, -1, false, lines)
    vim.bo[notification.buf_id].modifiable = false
  end

  local i = 0

  for active_token, _ in pairs(_active_notifications) do
    _update_position(active_token, i, #lines)
    i = i + 1
  end

  if is_done then
    vim.defer_fn(function()
      local active = _active_notifications[token]

      if not active then
        return
      end

      if vim.api.nvim_win_is_valid(active.win_id) then
        vim.api.nvim_win_close(active.win_id, true)
      end

      _active_notifications[token] = nil

      local index = 0

      for active_token, _ in pairs(_active_notifications) do
        local buf_height = vim.api.nvim_buf_line_count(
          _active_notifications[active_token].buf_id
        )

        _update_position(active_token, index, buf_height)

        index = index + 1
      end
    end, M.config.timeout)
  end
end

---@param err lsp.ResponseError|nil
---@param progress lsp.ProgressParams
---@param ctx lsp.HandlerContext
local function _lsp_handler(err, progress, ctx)
  local client = vim.lsp.get_client_by_id(ctx.client_id)

  if not client then
    return
  end

  local token = progress.token
  local value = progress.value

  if not value then
    return
  end

  if value.kind == "begin" or value.kind == "report" then
    _render_notification(token, {
      client = client.name,
      title = value.title,
      message = value.message,
      percentage = value.percentage,
    }, false)
  elseif value.kind == "end" then
    _render_notification(token, {
      client = client.name,
      title = value.title,
      message = value.message,
    }, true)
  end
end

function M.enable()
  if _enabled then
    return
  end

  _enabled = true

  if not _initialized then
    _initialized = true

    local previous = vim.lsp.handlers["$/progress"]

    vim.lsp.handlers["$/progress"] = function(err, progress, ctx)
      if _enabled then
        _lsp_handler(err, progress, ctx)
      end

      if previous then
        previous(err, progress, ctx)
      end
    end
  end
end

function M.disable()
  _enabled = false
end

---@param opts keystone.lspprogress.Config|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend(
    "force",
    _get_default_config(),
    opts or {}
  )

  if M.config.enabled then
    M.enable()
  else
    M.disable()
  end
end

return M
