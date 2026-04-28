local M = {}

---@class keystone.lspwords.Config
---@field enabled boolean

local lsp_protocol = require('vim.lsp.protocol')

local function _get_default_config()
  ---@type keystone.lspwords.Config
  return {
    enabled = true,
  }
end

---@type keystone.lspwords.Config
M.config = _get_default_config()

local enabled = false

function M.enable()
  if enabled then return end
  enabled = true

  local group = vim.api.nvim_create_augroup("keystone_lspwords", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function()
      if not enabled then return end
      vim.lsp.buf.clear_references()
      local clients = vim.lsp.get_clients({ bufnr = 0, method = lsp_protocol.Methods.textDocument_documentHighlight })
      if next(clients) then
        vim.lsp.buf.document_highlight()
      end
    end,
  })
end

function M.disable()
  if not enabled then return end
  enabled = false
  vim.api.nvim_del_augroup_by_name("keystone_lspwords")
  vim.lsp.buf.clear_references()
end

function M.clear()
  vim.lsp.buf.clear_references()
end

---@param opts keystone.lspwords.Config?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

  if M.config.enabled then
    M.enable()
  else
    M.disable()
  end
end

return M
