local M = {}

-- Plugin configuration
local config = {
  delay = 100,          -- Debounce delay for completion
  max_items = 15,       -- Maximum number of completion items
  signature_help = true -- Toggle function argument help
}

-- Internal state
local timer = vim.loop.new_timer()
local augroup_id = vim.api.nvim_create_augroup('PureCompletion', { clear = true })

-- Utility: Check if the completion popup menu is visible
local function pumvisible()
  return vim.fn.pumvisible() == 1
end

-- Convert LSP CompletionItemKind integers to readable text/icons
local kind_symbols = {
  [1] = 'Text', [2] = 'Method', [3] = 'Function', [4] = 'Constructor',
  [5] = 'Field', [6] = 'Variable', [7] = 'Class', [8] = 'Interface',
  [9] = 'Module', [10] = 'Property', [11] = 'Unit', [12] = 'Value',
  [13] = 'Enum', [14] = 'Keyword', [15] = 'Snippet', [16] = 'Color',
  [17] = 'File', [18] = 'Reference', [19] = 'Folder', [20] = 'EnumMember',
  [21] = 'Constant', [22] = 'Struct', [23] = 'Event', [24] = 'Operator',
  [25] = 'TypeParameter'
}

-- Process LSP completion items
local function process_lsp_results(results, prefix)
  local matches = {}
  for _, response in pairs(results) do
    if response.result then
      local items = response.result.items or response.result
      for _, item in ipairs(items) do
        local word = item.textEdit and item.textEdit.newText or item.insertText or item.label
        if vim.startswith(word, prefix) then
          table.insert(matches, {
            word = word,
            abbr = item.label,
            kind = kind_symbols[item.kind] or 'Unknown',
            menu = item.detail or '',
            icase = 1,
          })
        end
        if #matches >= config.max_items then break end
      end
    end
    if #matches >= config.max_items then break end
  end
  return matches
end

-- Request completion items from LSP
local function request_lsp_completion()
  if vim.api.nvim_get_mode().mode ~= 'i' or pumvisible() then return end

  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local line_num = cursor[1]
  local col = cursor[2]
  local line = vim.api.nvim_get_current_line()

  local line_to_cursor = line:sub(1, col)
  local start_col = vim.fn.matchstrpos(line_to_cursor, [[\k*$]])[2]
  
  if start_col == col then return end
  local prefix = line_to_cursor:sub(start_col + 1)

  local params = vim.lsp.util.make_position_params()
  vim.lsp.buf_request_all(0, 'textDocument/completion', params, function(results)
    if vim.api.nvim_get_mode().mode ~= 'i' or vim.api.nvim_win_get_cursor(win)[1] ~= line_num then
      return
    end

    local completion_items = process_lsp_results(results, prefix)
    if #completion_items > 0 then
      vim.fn.complete(start_col + 1, completion_items)
    end
  end)
end

-- Check and trigger Signature Help (Argument Help)
local function request_signature_help()
  if not config.signature_help or vim.api.nvim_get_mode().mode ~= 'i' then return end

  local params = vim.lsp.util.make_position_params()
  
  -- Request signature help from active clients
  vim.lsp.buf_request(0, 'textDocument/signatureHelp', params, function(err, result, ctx, _)
    if err or not result or not result.signatures or #result.signatures == 0 then return end
    
    -- Use Neovim's native signature help handler to draw the floating window beautifully
    vim.lsp.handlers['textDocument/signatureHelp'](err, result, ctx, {
      border = 'rounded',
      focusable = false, -- Don't steal focus from typing
    })
  end)
end

-- Combined debounced entrypoint for text/keystroke changes
local function on_text_changed()
  timer:stop()
  timer:start(config.delay, 0, vim.schedule_wrap(function()
    request_lsp_completion()
  end))
end

-- Separate trigger for function signatures when structural characters are typed
local function on_char_added()
  -- Get the character that was just typed
  local char = vim.v.char
  
  -- If user types an opening parenthesis or comma, check for signature arguments
  if char == '(' or char == ',' then
    vim.schedule(function()
      request_signature_help()
    end)
  end
end

-- Setup and self-registration
function M.setup(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})

  vim.api.nvim_clear_autocmds({ group = augroup_id })

  -- Autocmd for tracking normal alphanumeric typing (for completion popups)
  vim.api.nvim_create_autocmd({ 'TextChangedI' }, {
    group = augroup_id,
    callback = on_text_changed,
  })

  -- Autocmd specifically tracking special characters typed (for signature help triggers)
  vim.api.nvim_create_autocmd({ 'InsertCharPre' }, {
    group = augroup_id,
    callback = on_char_added,
  })

  -- Essential Completion Menu Navigations
  vim.keymap.set('i', '<Tab>', function()
    return pumvisible() and '<C-n>' or '<Tab>'
  end, { expr = true, replace_keycodes = true })

  vim.keymap.set('i', '<S-Tab>', function()
    return pumvisible() and '<C-p>' or '<S-Tab>'
  end, { expr = true, replace_keycodes = true })

  vim.keymap.set('i', '<CR>', function()
    return pumvisible() and '<C-y>' or '<CR>'
  end, { expr = true, replace_keycodes = true })
end

return M