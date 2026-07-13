--- keystone.lspcompletion
---
--- A self-contained LSP completion source, the pre-0.11 equivalent of Neovim's
--- built-in `vim.lsp.completion`. It owns `omnifunc` and everything downstream
--- of it: the `textDocument/completion` request, item conversion, snippet
--- expansion, `additionalTextEdits`/commands, `completionItem/resolve`, and a
--- documentation float. It knows nothing about *triggering* -- fire it with
--- native `<C-x><C-o>` or drive it from `keystone.completion`; either way it
--- populates the popup menu on its own. On Neovim >= 0.11 prefer the built-in
--- `vim.lsp.completion`; this module is the legacy fallback.
local M = {}

local itemutil = require("keystone.lspcompletion.items")

---@class keystone.lspcompletion.Config
---@field enabled boolean
---@field auto_setup boolean set `omnifunc` automatically on BufEnter (leaving an ftplugin/user slot alone)
---@field process_items? fun(items: table, base: string): table filter+sort hook
---@field snippet_insert? fun(snippet: string) snippet-expansion hook
---@field doc_float boolean show a documentation float for the selected item

---@return keystone.lspcompletion.Config
local function default_config()
  ---@type keystone.lspcompletion.Config
  return {
    enabled        = true,
    auto_setup     = true,
    process_items  = nil,
    snippet_insert = nil,
    doc_float      = true,
  }
end

M.config = default_config()

-- State ----------------------------------------------------------------------

local _ns = vim.api.nvim_create_namespace("keystone_lspcompletion")

--- Value written to 'omnifunc' when this module owns the slot.
local _omni_func = "v:lua.require'keystone.lspcompletion'.omnifunc"

--- Keys that re-enter our omnifunc once an async response is in.
local _omni_keys = vim.api.nvim_replace_termcodes("<C-x><C-o>", true, false, true)

local _has_native_snippet = vim.fn.has("nvim-0.10") == 1

---@class keystone.lspcompletion.State
---@field id integer monotonic request id
---@field status? "sent"|"received"|"done"|"canceled"
---@field is_incomplete boolean
---@field result? table
---@field resolved table<integer, table>
---@field cancel_fn? function
---@field init_base { lnum?: integer, col?: integer, length?: integer }

---@type keystone.lspcompletion.State
local _state = {
  id            = 0,
  status        = nil,
  is_incomplete = false,
  result        = nil,
  resolved      = {},
  cancel_fn     = nil,
  init_base     = { lnum = nil, col = nil, length = nil },
}

---@type integer? floating documentation window
local _doc_win

-- Utilities ------------------------------------------------------------------

---@return keystone.lspcompletion.Config
local function get_config()
  local override = vim.b.keystone_lspcompletion_config
  if override == nil then return M.config end
  return vim.tbl_deep_extend("force", M.config, override)
end

---@return boolean
local function pumvisible() return vim.fn.pumvisible() > 0 end

---@return boolean
local function in_float()
  return vim.api.nvim_win_get_config(0).relative ~= ""
end

---@param id integer
---@param delete_text? boolean
---@return table
local function pop_extmark(id, delete_text)
  local data = vim.api.nvim_buf_get_extmark_by_id(0, _ns, id, { details = true })
  vim.api.nvim_buf_del_extmark(0, _ns, id)
  local details = data[3] --[[@as any]]
  if not delete_text or data[1] == nil or details.end_row == nil then return data end
  local sr, sc = data[1] --[[@as integer]], data[2] --[[@as integer]]
  local er, ec = details.end_row --[[@as integer]], details.end_col --[[@as integer]]
  if sr < er or (sr == er and sc < ec) then
    vim.api.nvim_buf_set_text(0, sr, sc, er, ec, { "" })
  end
  return data
end

-- LSP helpers ----------------------------------------------------------------

--- Buffer-attached clients advertising `capability` (a top-level key under
--- `server_capabilities`, e.g. "completionProvider").
---@param capability string
---@return vim.lsp.Client[]
local function clients_with(capability)
  return vim.tbl_filter(function(c)
    return vim.tbl_get(c.server_capabilities, capability) ~= nil
  end, vim.lsp.get_clients({ bufnr = 0 }))
end

---@param capability? string
---@return boolean
local function has_lsp_clients(capability)
  if not capability then
    return not vim.tbl_isempty(vim.lsp.get_clients({ bufnr = 0 }))
  end
  return not vim.tbl_isempty(clients_with(capability))
end

---@param char string
---@return boolean
local function is_completion_trigger(char)
  for _, client in ipairs(clients_with("completionProvider")) do
    local triggers = vim.tbl_get(client.server_capabilities, "completionProvider", "triggerCharacters")
    if vim.tbl_contains(triggers or {}, char) then return true end
  end
  return false
end

local function cancel_lsp()
  if vim.tbl_contains({ "sent", "received" }, _state.status) then
    if _state.cancel_fn then _state.cancel_fn() end
    _state.status = "canceled"
  end
  _state.result, _state.cancel_fn = nil, nil
end

---@param id integer
---@return boolean
local function lsp_request_current(id)
  return _state.id == id and _state.status == "sent"
end

---@param request_result table
---@param processor fun(result: table, client_id: integer): table?
---@return table
local function collect_lsp_results(request_result, processor)
  if not request_result then return {} end
  local res = {}
  for client_id, item in pairs(request_result) do
    if not (item.err or item.error) and item.result then
      vim.list_extend(res, processor(item.result, client_id) or {})
    end
  end
  return res
end

---@param rd table
---@return table?
local function lsp_edit_range(rd)
  if rd.err or rd.error or type(rd.result) ~= "table" then return end
  local er = vim.tbl_get(rd.result, "itemDefaults", "editRange")
  if type(er) == "table" then return er.insert or er end
  local items = rd.result.items or rd.result
  for _, item in ipairs(items) do
    if type(item.textEdit) == "table" then return item.textEdit.range or item.textEdit.insert end
  end
end

---@param lsp_result table
---@return table from
---@return table to
local function completion_range(lsp_result)
  local pos = vim.api.nvim_win_get_cursor(0)
  for _, rd in pairs(lsp_result or {}) do
    local range = lsp_edit_range(rd)
    if range then return { range.start.line + 1, range.start.character }, pos end
  end
  local line = vim.api.nvim_get_current_line()
  return { pos[1], vim.fn.match(line:sub(1, pos[2]), "\\k*$") }, pos
end

---@type fun(context: table): function|table
local position_params
if vim.fn.has("nvim-0.11") == 1 then
  position_params = function(context)
    return function(client, _)
      local res = vim.lsp.util.make_position_params(0, client.offset_encoding) --[[@as any]]
      res.context = context
      return res
    end
  end
else
  position_params = function(context)
    local res = vim.lsp.util.make_position_params(0, "utf-16") --[[@as any]]
    res.context = context
    return res
  end
end

--- Build a completion context by inspecting the just-typed character, so the
--- source is self-driving: no trigger layer has to hand us a triggerKind.
---@return table
local function build_context()
  local kinds = vim.lsp.protocol.CompletionTriggerKind
  local col   = vim.api.nvim_win_get_cursor(0)[2]
  local line  = vim.api.nvim_get_current_line()
  local prev  = col > 0 and line:sub(col, col) or ""
  if prev ~= "" and is_completion_trigger(prev) then
    return { triggerKind = kinds.TriggerCharacter, triggerCharacter = prev }
  end
  if _state.is_incomplete then
    return { triggerKind = kinds.TriggerForIncompleteCompletions }
  end
  return { triggerKind = kinds.Invoked }
end

-- Completion flow ------------------------------------------------------------

---@param keep_incomplete? boolean
---@param keep_resolved? boolean
local function stop(keep_incomplete, keep_resolved)
  cancel_lsp()
  if not keep_incomplete then _state.is_incomplete = false end
  if not keep_resolved then _state.resolved = {} end
end

local function request_completion()
  cancel_lsp() -- keep a single request in flight regardless of caller
  local req_id      = _state.id + 1
  _state.id         = req_id
  _state.status     = "sent"

  local ctx         = build_context()
  local buf_id      = vim.api.nvim_get_current_buf()

  _state.cancel_fn  = vim.lsp.buf_request_all(buf_id, "textDocument/completion", position_params(ctx),
    function(result)
      if not lsp_request_current(req_id) then return end
      _state.status = "received"
      _state.result = result
      -- Re-feed our own omnifunc so it re-enters and returns items now that the
      -- response is in. Skip if a menu is already up to avoid disrupting it.
      if vim.fn.mode() == "i" and not pumvisible() then
        vim.api.nvim_feedkeys(_omni_keys, "n", false)
      end
    end)
end

-- LSP extra actions (snippet insert, additional text edits, commands) --------

---@param client_id? integer
---@param text_edits? table
local function apply_text_edits(client_id, text_edits)
  if text_edits == nil then return end
  local enc = client_id and vim.lsp.get_client_by_id(client_id).offset_encoding or "utf-16"
  vim.lsp.util.apply_text_edits(text_edits, vim.api.nvim_get_current_buf(), enc)
end

---@param client_id? integer
---@param command? table
local function exec_command(client_id, command)
  if command == nil or client_id == nil then return end
  local client = vim.lsp.get_client_by_id(client_id)
  if client and client.exec_cmd then
    client:exec_cmd(command, { bufnr = vim.api.nvim_get_current_buf() })
  end
end

---@param client_id? integer
---@param text_edits? table
---@param from table
---@param to table
---@return table from
---@return table to
local function tracked_text_edits(client_id, text_edits, from, to)
  if text_edits == nil then return from, to end

  local cur       = vim.api.nvim_win_get_cursor(0)
  local cursor_id = vim.api.nvim_buf_set_extmark(0, _ns, cur[1] - 1, cur[2], {})
  local from_id   = vim.api.nvim_buf_set_extmark(0, _ns, from[1] - 1, from[2], {})
  local to_id     = vim.api.nvim_buf_set_extmark(0, _ns, to[1] - 1, to[2], {})

  apply_text_edits(client_id, text_edits)

  local cd = pop_extmark(cursor_id)
  pcall(vim.api.nvim_win_set_cursor, 0, { cd[1] + 1, cd[2] })

  local fd = pop_extmark(from_id)
  local td = pop_extmark(to_id)
  return { fd[1] + 1, fd[2] }, { td[1] + 1, td[2] }
end

---@param lsp_data table
local function apply_completion_extras(lsp_data)
  local item = _state.resolved[lsp_data.item_id] or lsp_data.item
  if item.additionalTextEdits == nil and item.command == nil and not lsp_data.needs_snippet_insert then return end
  local snippet  = lsp_data.needs_snippet_insert and itemutil.word(item) or nil

  local cur      = vim.api.nvim_win_get_cursor(0)
  local track_id = vim.api.nvim_buf_set_extmark(0, _ns, cur[1] - 1, cur[2], {
    end_row = cur[1] - 1,
    end_col = cur[2],
    right_gravity = false,
    end_right_gravity = true,
  })

  vim.schedule(function()
    if vim.fn.mode() ~= "i" then return end

    if snippet ~= nil then
      pop_extmark(track_id, true)
      pcall(vim.api.nvim_win_set_cursor, 0, cur)
    end

    if snippet == nil then
      apply_text_edits(item.client_id, item.additionalTextEdits)
      exec_command(item.client_id, item.command)
      return
    end

    local ib   = _state.init_base
    local from = { ib.lnum, ib.col }
    local to   = vim.api.nvim_win_get_cursor(0)
    pcall(vim.api.nvim_buf_set_text, 0, from[1] - 1, from[2], to[1] - 1, to[2],
      { string.rep("x", ib.length) })
    to = { from[1], from[2] + ib.length }

    local prefix_id = vim.api.nvim_buf_set_extmark(0, _ns, from[1] - 1, from[2],
      { end_row = to[1] - 1, end_col = to[2] })

    local er = lsp_edit_range({ result = { item } })
    if er then
      local n  = vim.api.nvim_buf_line_count(0)
      local sl = math.min(er.start.line + 1, n)
      local el = math.min(er["end"].line + 1, n)
      local sc = math.min(er.start.character, vim.fn.getline(sl):len())
      local ec = math.min(er["end"].character, vim.fn.getline(el):len())
      from, to = { sl, sc }, { el, ec }
    end

    from, to = tracked_text_edits(item.client_id, item.additionalTextEdits, from, to)

    pcall(vim.api.nvim_buf_set_text, 0, from[1] - 1, from[2], to[1] - 1, to[2], { "" })
    vim.api.nvim_win_set_cursor(0, from)
    pop_extmark(prefix_id, true)

    local insert = get_config().snippet_insert or M.default_snippet_insert
    insert(snippet)
  end)
end

-- Documentation float --------------------------------------------------------

local function close_doc_win()
  if _doc_win and vim.api.nvim_win_is_valid(_doc_win) then
    vim.api.nvim_win_close(_doc_win, true)
  end
  _doc_win = nil
end

---@param documentation? string|table
local function show_doc_content(documentation)
  local lines
  if documentation then
    lines = vim.lsp.util.convert_input_to_markdown_lines(documentation)
    lines = vim.tbl_filter(function(l) return l ~= "" end, lines)
    if vim.tbl_isempty(lines) then lines = nil end
  end
  vim.schedule(function()
    close_doc_win()
    if not pumvisible() or not lines then return end

    local pum = vim.fn.pum_getpos()
    if vim.tbl_isempty(pum) then return end

    local pum_right = pum.col + pum.width + (pum.scrollbar and 1 or 0)
    local offset_x  = pum_right - (vim.fn.screencol() - 1)

    local _, win    = vim.lsp.util.open_floating_preview(lines, "markdown", {
      border     = "rounded",
      max_width  = 60,
      max_height = 20,
      focusable  = false,
      offset_x   = offset_x,
    })
    _doc_win         = win
  end)
end

---@return table?
local function selected_completed_item()
  local info = vim.fn.complete_info({ "selected", "items" })
  if info.selected < 0 then return nil end
  return info.items[info.selected + 1]
end

local function on_complete_changed()
  -- v:completed_item is only populated by <C-n>/<C-p>; <Up>/<Down> merely
  -- highlight a match without inserting it, so complete_info() is used instead.
  local completed_item = selected_completed_item()
  local lsp_data = completed_item and vim.tbl_get(completed_item, "user_data", "lsp")
  if not lsp_data then
    show_doc_content(nil); return
  end

  local item = _state.resolved[lsp_data.item_id] or lsp_data.item
  if item.documentation then
    show_doc_content(item.documentation)
    return
  end

  local client = vim.lsp.get_client_by_id(item.client_id)
  if not client or not vim.tbl_get(client, "server_capabilities", "completionProvider", "resolveProvider") then
    show_doc_content(nil)
    return
  end

  local item_id = lsp_data.item_id
  client:request("completionItem/resolve", item, function(err, result)
    if err or not result then return end
    _state.resolved[item_id] = result
    vim.schedule(function()
      if not pumvisible() then return end
      local cur_item = selected_completed_item()
      local cur = cur_item and vim.tbl_get(cur_item, "user_data", "lsp")
      if cur and cur.item_id == item_id then show_doc_content(result.documentation) end
    end)
  end, vim.api.nvim_get_current_buf())
end

local function on_complete_done()
  if _state.status == "received" then return end
  local lsp_data = vim.tbl_get(vim.v.completed_item, "user_data", "lsp")
  if lsp_data ~= nil then apply_completion_extras(lsp_data) end
  stop()
end

-- Setup ----------------------------------------------------------------------

local function setup_hl()
  vim.api.nvim_set_hl(0, "KeystoneCompletionDeprecated", { default = true, link = "DiagnosticDeprecated" })
end

---@param config keystone.lspcompletion.Config
local function setup_autocmds(config)
  local gr = vim.api.nvim_create_augroup("keystone_lspcompletion", { clear = true })
  ---@param event string|string[]
  ---@param pattern string
  ---@param cb function
  local function au(event, pattern, cb)
    vim.api.nvim_create_autocmd(event, { group = gr, pattern = pattern, callback = cb })
  end

  if config.doc_float then
    au("CompleteChanged", "*", on_complete_changed)
  end
  au("ModeChanged", "i*:[^i]*", function()
    stop(); close_doc_win()
  end)
  au("CompleteDonePre", "*", function()
    close_doc_win(); on_complete_done()
  end)

  if config.auto_setup then
    -- Claim `omnifunc` when it is unset or already ours, so an ftplugin's or the
    -- user's own omnifunc is left alone. Read config live to honor a per-buffer
    -- `enabled`.
    au("BufEnter", "*", function()
      local cfg = get_config()
      if not cfg.enabled then return end
      local cur = vim.bo.omnifunc
      if cur == "" or cur == _omni_func then vim.bo.omnifunc = _omni_func end
    end)
  end
end

-- Public API -----------------------------------------------------------------

--- Two-stage LSP completion function. Set as 'omnifunc'.
---@param findstart 0|1
---@param base string
---@return integer|table|nil
M.omnifunc = function(findstart, base)
  if not has_lsp_clients("completionProvider") or _state.status == "sent" then
    return findstart == 1 and -3 or {}
  end

  if _state.status ~= "received" then
    request_completion()
    return findstart == 1 and -3 or {}
  end

  if findstart == 1 then
    local from, to = completion_range(_state.result)
    _state.init_base = { lnum = from[1], col = from[2], length = math.max(to[2] - from[2], 0) }
    return from[2]
  end

  local is_incomplete = false
  local all_items     = collect_lsp_results(_state.result, function(response, client_id)
    is_incomplete = is_incomplete or (response.isIncomplete == true)
    local items   = response.items or response
    if type(items) ~= "table" then return {} end
    items = itemutil.apply_defaults(items, response.itemDefaults)
    for _, item in ipairs(items) do item.client_id = client_id end
    return items
  end)

  local process       = get_config().process_items or M.default_process_items
  all_items           = process(all_items, base)
  local candidates    = itemutil.to_vim(all_items)

  _state.status        = "done"
  _state.is_incomplete = is_incomplete

  return candidates
end

--- Filter and sort LSP completion items.
---@param items table
---@param base string
---@param opts? { filtersort?: function, kind_priority?: table }
---@return table
M.default_process_items = function(items, base, opts)
  opts = opts or {}
  local res = opts.filtersort and opts.filtersort(items, base) or itemutil.filter_sort(items, base)
  if opts.kind_priority then res = itemutil.sort_by_kind(res, opts.kind_priority) end
  itemutil.add_hlgroups(res)
  return res
end

--- Insert a snippet at cursor.
---@param snippet string
M.default_snippet_insert = function(snippet)
  if _has_native_snippet then return vim.snippet.expand(snippet) end
  local pos   = vim.api.nvim_win_get_cursor(0)
  local lines = vim.split(snippet, "\n")
  vim.api.nvim_buf_set_text(0, pos[1] - 1, pos[2], pos[1] - 1, pos[2], lines)
  local n       = #lines
  local new_pos = n == 1 and { pos[1], pos[2] + lines[n]:len() } or { pos[1] + n - 1, lines[n]:len() }
  vim.api.nvim_win_set_cursor(0, new_pos)
end

--- LSP capabilities declared by this module.
---@return table
M.get_lsp_capabilities = function()
  return {
    textDocument = {
      completion = {
        dynamicRegistration = false,
        completionItem = {
          snippetSupport          = true,
          commitCharactersSupport = false,
          documentationFormat     = { "markdown", "plaintext" },
          deprecatedSupport       = true,
          preselectSupport        = false,
          insertReplaceSupport    = true,
          resolveSupport          = { properties = { "additionalTextEdits", "detail", "documentation" } },
          insertTextModeSupport   = { valueSet = { 1 } },
          labelDetailsSupport     = true,
        },
        completionItemKind = {
          valueSet = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25 },
        },
        contextSupport = true,
        insertTextMode = 1,
        completionList = {
          itemDefaults = { "commitCharacters", "editRange", "insertTextFormat", "insertTextMode", "data" },
        },
      },
    },
  }
end

--- Stop any in-flight request and clear per-completion state.
M.stop = function()
  stop()
end

---@param opts keystone.lspcompletion.Config?
M.setup = function(opts)
  M.config = vim.tbl_deep_extend("force", default_config(), opts or {})
  setup_hl()
  if M.config.enabled then
    setup_autocmds(M.config)
  end
end

return M
