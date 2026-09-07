---LSP progress section provider.
---Tracks `$/progress` tokens via the `LspProgress` autocmd and renders the
---active ones for clients attached to the rendered buffer.
local M = {}

---@class keystone.statusline.LspToken
---@field name       string
---@field client_id  integer
---@field percentage integer?

---@type table<string|integer, keystone.statusline.LspToken>
local _progress = {}

---@param opts keystone.statusline.RenderOpts
---@return string full, string short
function M.render(opts)
  local bufnr = opts.bufnr
  local parts = {}
  for _, token in pairs(_progress) do
    if vim.lsp.buf_is_attached(bufnr, token.client_id) then
      parts[#parts + 1] = token.percentage
          and string.format("%s %d%%%%", token.name, token.percentage)
          or token.name
    end
  end
  local hl = opts.is_current and "KeystoneSLLspProgress" or "KeystoneSLLspProgressNC"
  if #parts == 0 then return "", "" end
  -- Short form drops the client names/percentages, keeping just the icon.
  return string.format("%%#%s#󰒓 %s%%*", hl, table.concat(parts, "  ")),
      string.format("%%#%s#󰒓 %%*", hl)
end

local _group = nil

---@param on_change fun() called whenever the tracked progress state changes
function M.enable(on_change)
  vim.api.nvim_set_hl(0, "KeystoneSLLspProgress", { default = true, link = "StatusLine" })
  vim.api.nvim_set_hl(0, "KeystoneSLLspProgressNC", { default = true, link = "StatusLineNC" })

  _group = vim.api.nvim_create_augroup("keystone_statusline_lsp_progress", { clear = true })
  vim.api.nvim_create_autocmd("LspProgress", {
    group = _group,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if not client then return end
      local params = ev.data.params
      local val    = params and params.value
      if not val then return end
      local token = params.token
      if val.kind == "end" then
        _progress[token] = nil
      else
        _progress[token] = { name = client.name, client_id = ev.data.client_id, percentage = val.percentage }
      end
      on_change()
    end,
  })
end

function M.disable()
  _progress = {}
  if _group then
    vim.api.nvim_del_augroup_by_id(_group)
    _group = nil
  end
end

return M
