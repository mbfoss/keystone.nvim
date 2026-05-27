local M = {}

---@class keystone.complete.LspConfig
---@field source_func "completefunc"|"omnifunc"
---@field auto_setup boolean
---@field process_items? fun(items: table, base: string): table
---@field snippet_insert? fun(snippet: string)

---@class keystone.complete.MappingsConfig
---@field force_twostep string
---@field force_fallback string

---@class keystone.complete.Config
---@field enabled boolean
---@field delay integer
---@field lsp_completion keystone.complete.LspConfig
---@field fallback_action string|function
---@field mappings keystone.complete.MappingsConfig

local function _get_default_config()
  ---@type keystone.complete.Config
  return {
    enabled = true,
    delay   = 100,
    lsp_completion = {
      source_func    = "completefunc",
      auto_setup     = true,
      process_items  = nil,
      snippet_insert = nil,
    },
    fallback_action = "<C-n>",
    mappings = {
      force_twostep  = "<C-Space>",
      force_fallback = "<A-Space>",
    },
  }
end

---@type keystone.complete.Config
M.config = _get_default_config()

-- Internal helpers -----------------------------------------------------------
local H = {}

H.ns_id = vim.api.nvim_create_namespace("keystone_complete")

H.keys = {
  completefunc = vim.api.nvim_replace_termcodes("<C-x><C-u>", true, false, true),
  omnifunc     = vim.api.nvim_replace_termcodes("<C-x><C-o>", true, false, true),
  ctrl_n       = vim.api.nvim_replace_termcodes("<C-g><C-g><C-n>", true, false, true),
}

H.text_changed_id = 0

H.completion = {
  fallback        = true,
  force           = false,
  source          = nil,
  text_changed_id = 0,
  timer           = vim.uv.new_timer(),
  lsp = {
    id            = 0,
    status        = nil,
    is_incomplete = false,
    result        = nil,
    resolved      = {},
    cancel_fun    = nil,
    context       = nil,
  },
  init_base = { lnum = nil, col = nil, length = nil },
}

H.get_config = function()
  return vim.tbl_deep_extend("force", M.config, vim.b.keystone_complete_config or {})
end

-- Setup ----------------------------------------------------------------------
H.apply_config = function(config)
  local function map(lhs, rhs, opts)
    if lhs == "" then return end
    vim.keymap.set("i", lhs, rhs, vim.tbl_extend("force", { silent = true }, opts or {}))
  end

  map(config.mappings.force_twostep, M.complete_twostage, { desc = "Complete with two-stage" })
  map(config.mappings.force_fallback, M.complete_fallback, { desc = "Complete with fallback" })

  local was_set = vim.api.nvim_get_option_info2("completeopt", { scope = "global" }).was_set
  if not was_set then vim.o.completeopt = "menuone,noselect" end

  was_set = vim.api.nvim_get_option_info2("shortmess", { scope = "global" }).was_set
  if not was_set then vim.opt.shortmess:append("c") end

  was_set = vim.api.nvim_get_option_info2("complete", { scope = "global" }).was_set
  if not was_set and config.fallback_action == "<C-n>" then vim.opt.complete:remove("t") end
end

H.create_autocommands = function(config)
  local gr = vim.api.nvim_create_augroup("keystone_complete", { clear = true })
  local au = function(event, pattern, cb)
    vim.api.nvim_create_autocmd(event, { group = gr, pattern = pattern, callback = cb })
  end

  au("InsertCharPre",  "*", H.auto_completion)
  au("CursorMovedI",   "*", H.auto_signature)
  au("ModeChanged", "i*:[^i]*", function() M.stop() end)
  au("CompleteDonePre","*", H.on_completedonepre)
  au("TextChangedI",   "*", function() H.text_changed_id = H.text_changed_id + 1 end)
  au("TextChangedP",   "*", function() H.text_changed_id = H.text_changed_id + 1 end)

  if config.lsp_completion.auto_setup then
    local sf = config.lsp_completion.source_func
    au("BufEnter", "*", function() vim.bo[sf] = "v:lua.require'keystone.complete'.completefunc_lsp" end)
  end
end

H.create_default_hl = function()
  vim.api.nvim_set_hl(0, "KeystoneCompletionDeprecated", { default = true, link = "DiagnosticDeprecated" })
end

-- Auto events ----------------------------------------------------------------
H.auto_completion = function()
  H.completion.timer:stop()

  local is_incomplete = H.completion.lsp.is_incomplete
  local is_trigger    = H.is_lsp_trigger(vim.v.char, "completion")
  local force         = is_trigger or is_incomplete

  if force then
    H.stop_completion(false, is_incomplete)
  elseif H.pumvisible() then
    return H.stop_completion(true, false, true)
  elseif not H.is_char_keyword(vim.v.char) then
    return H.stop_completion(false)
  end

  H.completion.fallback, H.completion.force = not force, force
  H.completion.text_changed_id = H.text_changed_id + 1

  if H.completion.source == "lsp" then return H.trigger_fallback() end

  local trigger_kind_name = is_trigger and "TriggerCharacter"
      or (is_incomplete and "TriggerForIncompleteCompletions" or "Invoked")
  local trigger_kind = vim.lsp.protocol.CompletionTriggerKind[trigger_kind_name]
  local trigger_char = trigger_kind_name == "TriggerCharacter" and vim.v.char or nil
  H.completion.lsp.context = { triggerKind = trigger_kind, triggerCharacter = trigger_char }

  local delay = is_incomplete and 0 or H.get_config().delay
  H.completion.timer:start(delay, 0, vim.schedule_wrap(H.trigger_twostep))
end

H.auto_signature = function()
  if not H.has_lsp_clients("signatureHelpProvider") then return end
  if H.is_lsp_trigger(H.get_left_char(), "signature") then
    vim.lsp.buf.signature_help()
  end
end

H.on_completedonepre = function()
  if H.completion.lsp.status == "received" then return end
  local lsp_data = H.table_get(vim.v.completed_item, { "user_data", "lsp" })
  if lsp_data ~= nil then H.make_lsp_extra_actions(lsp_data) end
  M.stop()
end

-- Completion triggers --------------------------------------------------------
H.trigger_twostep = function()
  local allow = (vim.fn.mode() == "i")
      and (H.completion.force or (H.completion.text_changed_id == H.text_changed_id))
  if not allow then return end

  if H.has_lsp_clients("completionProvider") and H.has_lsp_completion() then
    H.trigger_lsp()
  elseif H.completion.fallback then
    H.trigger_fallback()
  end
end

H.trigger_lsp = function()
  if vim.fn.mode() ~= "i" or (H.pumvisible() and not H.completion.force) then return end
  if H.completion.lsp.status ~= "received" then return H.make_completion_request() end
  local keys = H.keys[H.get_config().lsp_completion.source_func]
  vim.api.nvim_feedkeys(keys, "n", false)
end

H.trigger_fallback = function()
  local has_popup = H.pumvisible() and not H.completion.force
  if has_popup or vim.fn.mode() ~= "i" then return end

  H.completion.source = "fallback"
  local action = H.get_config().fallback_action
  if vim.is_callable(action) then return action() end
  if type(action) ~= "string" then return end

  if action == "<C-n>" then
    vim.api.nvim_feedkeys(H.keys.ctrl_n, "n", false)
    return
  end
  local keys = vim.api.nvim_replace_termcodes("<C-g><C-g>" .. action, true, false, true)
  vim.api.nvim_feedkeys(keys, "n", false)
end

-- Stop -----------------------------------------------------------------------
H.stop_completion = function(keep_source, keep_lsp_incomplete, keep_lsp_resolved)
  H.completion.timer:stop()
  H.cancel_lsp()
  H.completion.lsp.context = nil
  H.completion.fallback, H.completion.force = true, false
  if not keep_source then H.completion.source = nil end
  if not keep_lsp_incomplete then H.completion.lsp.is_incomplete = false end
  if not keep_lsp_resolved then H.completion.lsp.resolved = {} end
end

-- LSP helpers ----------------------------------------------------------------
H.has_lsp_clients = function(capability)
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if vim.tbl_isempty(clients) then return false end
  if not capability then return true end
  for _, c in pairs(clients) do
    if H.table_get(c.server_capabilities, capability) then return true end
  end
  return false
end

H.has_lsp_completion = function()
  local sf = H.get_config().lsp_completion.source_func
  return vim.bo[sf] == "v:lua.require'keystone.complete'.completefunc_lsp"
end

H.is_lsp_trigger = function(char, kind)
  local providers = { completion = "completionProvider", signature = "signatureHelpProvider" }
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
    local triggers = H.table_get(client, { "server_capabilities", providers[kind], "triggerCharacters" })
    if vim.tbl_contains(triggers or {}, char) then return true end
  end
  return false
end

H.cancel_lsp = function()
  local c = H.completion
  if vim.tbl_contains({ "sent", "received" }, c.lsp.status) then
    if c.lsp.cancel_fun then c.lsp.cancel_fun() end
    c.lsp.status = "canceled"
  end
  c.lsp.result, c.lsp.cancel_fun = nil, nil
end

H.process_lsp_response = function(request_result, processor)
  if not request_result then return {} end
  local res = {}
  for client_id, item in pairs(request_result) do
    if not (item.err or item.error) and item.result then
      vim.list_extend(res, processor(item.result, client_id) or {})
    end
  end
  return res
end

H.is_lsp_current = function(id)
  return H.completion.lsp.id == id and H.completion.lsp.status == "sent"
end

-- Completion request ---------------------------------------------------------
H.make_completion_request = function()
  local current_id = H.completion.lsp.id + 1
  H.completion.lsp.id     = current_id
  H.completion.lsp.status = "sent"

  local ctx    = H.completion.lsp.context or { triggerKind = vim.lsp.protocol.CompletionTriggerKind.Invoked }
  local buf_id = vim.api.nvim_get_current_buf()
  local params = H.make_position_params(ctx)

  local cancel_fun = vim.lsp.buf_request_all(buf_id, "textDocument/completion", params, function(result)
    if not H.is_lsp_current(current_id) then return end
    H.completion.lsp.status = "received"
    H.completion.lsp.result = result
    H.trigger_lsp()
  end)

  H.completion.lsp.cancel_fun = cancel_fun
end

H.apply_item_defaults = function(items, defaults)
  if type(defaults) ~= "table" then return items end
  local er, has_er = defaults.editRange, type(defaults.editRange) == "table"
  local er_range   = (er or {}).start ~= nil and er or nil
  for _, item in ipairs(items) do
    item.commitCharacters = item.commitCharacters or defaults.commitCharacters
    item.data             = item.data             or defaults.data
    item.insertTextFormat = item.insertTextFormat or defaults.insertTextFormat
    item.insertTextMode   = item.insertTextMode   or defaults.insertTextMode
    if has_er then
      item.textEdit         = item.textEdit         or {}
      item.textEdit.newText = item.textEdit.newText or item.textEditText or item.label
      item.textEdit.range   = item.textEdit.range   or er_range
      item.textEdit.insert  = item.textEdit.insert  or er.insert
      item.textEdit.replace = item.textEdit.replace or er.replace
    end
  end
  return items
end

H.lsp_items_to_complete_items = function(items)
  if vim.tbl_count(items) == 0 then return {} end

  local res        = {}
  local item_kinds = vim.lsp.protocol.CompletionItemKind
  local snip_kind  = vim.lsp.protocol.CompletionItemKind.Snippet
  local snip_fmt   = vim.lsp.protocol.InsertTextFormat.Snippet

  for i, item in ipairs(items) do
    local word         = H.get_completion_word(item)
    local is_snip_kind = item.kind == snip_kind
    local is_snip_fmt  = item.insertTextFormat == snip_fmt
    local has_snip_features = (word:find("[^\\]%${?%w")
        or word:find("^%${?%w")
        or word:find("[\n\t]")) ~= nil
    local needs_snippet = (is_snip_kind or is_snip_fmt) and has_snip_features

    local details      = item.labelDetails or {}
    local snip_marker  = needs_snippet and "S" or ""
    local detail, desc = details.detail or "", details.description or ""
    local pad          = (snip_marker ~= "" and detail ~= "") and " " or ""
    local label_detail = snip_marker .. pad .. detail
    pad                = (label_detail ~= "" and desc ~= "") and " " or ""
    label_detail       = label_detail .. pad .. desc

    table.insert(res, {
      word  = needs_snippet and H.lsp_filterword(item) or word,
      abbr  = item.label,
      abbr_hlgroup = item.abbr_hlgroup,
      kind  = item_kinds[item.kind] or "Unknown",
      kind_hlgroup = item.kind_hlgroup,
      menu  = label_detail,
      info  = needs_snippet and word or nil,
      icase = 1, dup = 1, empty = 1,
      user_data = { lsp = { item = item, item_id = i, needs_snippet_insert = needs_snippet } },
    })
  end
  return res
end

H.lsp_filterword  = function(x) return x.filterText or x.label end
H.lsp_item_compare = function(a, b) return (a.sortText or a.label) < (b.sortText or b.label) end
H.get_completion_word = function(item)
  return H.table_get(item, { "textEdit", "newText" }) or item.insertText or H.lsp_filterword(item) or ""
end

H.lsp_arrange_by_kind = function(items, kind_priority)
  H.ensure_kind_map()
  local raw = {}
  for i, item in ipairs(items) do
    local priority = kind_priority[H.kind_map[item.kind]] or 100
    if priority >= 0 then table.insert(raw, { priority, i, item }) end
  end
  table.sort(raw, function(a, b) return a[1] > b[1] or (a[1] == b[1] and a[2] < b[2]) end)
  return vim.tbl_map(function(x) return x[3] end, raw)
end

H.ensure_kind_map = function()
  if H.kind_map then return end
  H.kind_map = {}
  for k, v in pairs(vim.lsp.protocol.CompletionItemKind) do
    if type(k) == "string" and type(v) == "number" then H.kind_map[v] = k end
  end
end

H.add_item_hlgroups = function(items)
  local deprecated_tag = vim.lsp.protocol.CompletionTag.Deprecated
  for _, item in ipairs(items) do
    local is_deprecated = item.deprecated
        or (item.tags and vim.list_contains(item.tags, deprecated_tag))
    item.abbr_hlgroup = item.abbr_hlgroup
        or (is_deprecated and "KeystoneCompletionDeprecated" or nil)
  end
  return items
end

-- Snippet / extra LSP actions ------------------------------------------------
H.make_lsp_extra_actions = function(lsp_data)
  local item    = H.completion.lsp.resolved[lsp_data.item_id] or lsp_data.item
  if item.additionalTextEdits == nil and item.command == nil and not lsp_data.needs_snippet_insert then return end
  local snippet = lsp_data.needs_snippet_insert and H.get_completion_word(item) or nil

  local cur = vim.api.nvim_win_get_cursor(0)
  local track_id = vim.api.nvim_buf_set_extmark(0, H.ns_id, cur[1] - 1, cur[2], {
    end_row = cur[1] - 1, end_col = cur[2],
    right_gravity = false, end_right_gravity = true,
  })

  vim.schedule(function()
    if vim.fn.mode() ~= "i" then return end

    if snippet ~= nil then
      H.del_extmark(track_id, true)
      pcall(vim.api.nvim_win_set_cursor, 0, cur)
    end

    if snippet == nil then
      H.apply_text_edits(item.client_id, item.additionalTextEdits)
      H.exec_command(item.client_id, item.command)
      return
    end

    local init_base = H.completion.init_base
    local from      = { init_base.lnum, init_base.col }
    local to        = vim.api.nvim_win_get_cursor(0)
    local prefix    = string.rep("x", init_base.length)
    pcall(vim.api.nvim_buf_set_text, 0, from[1] - 1, from[2], to[1] - 1, to[2], { prefix })
    to = { from[1], from[2] + init_base.length }
    local prefix_id = vim.api.nvim_buf_set_extmark(0, H.ns_id, from[1] - 1, from[2],
      { end_row = to[1] - 1, end_col = to[2] })

    local edit_range = H.get_lsp_edit_range({ result = { item } })
    if edit_range then
      local n  = vim.api.nvim_buf_line_count(0)
      local sl = math.min(edit_range.start.line + 1, n)
      local el = math.min(edit_range["end"].line + 1, n)
      local sc = math.min(edit_range.start.character, vim.fn.getline(sl):len())
      local ec = math.min(edit_range["end"].character, vim.fn.getline(el):len())
      from, to = { sl, sc }, { el, ec }
    end

    from, to = H.apply_tracked_text_edits(item.client_id, item.additionalTextEdits, from, to)

    pcall(vim.api.nvim_buf_set_text, 0, from[1] - 1, from[2], to[1] - 1, to[2], { "" })
    vim.api.nvim_win_set_cursor(0, from)
    H.del_extmark(prefix_id, true)

    local insert = H.get_config().lsp_completion.snippet_insert or M.default_snippet_insert
    insert(snippet)
  end)
end

H.apply_text_edits = function(client_id, text_edits)
  if text_edits == nil then return end
  local enc = client_id and vim.lsp.get_client_by_id(client_id).offset_encoding or "utf-16"
  vim.lsp.util.apply_text_edits(text_edits, vim.api.nvim_get_current_buf(), enc)
end

H.exec_command = function(client_id, command)
  if command == nil or client_id == nil then return end
  local client = vim.lsp.get_client_by_id(client_id)
  if client and client.exec_cmd then
    client:exec_cmd(command, { bufnr = vim.api.nvim_get_current_buf() })
  end
end

H.apply_tracked_text_edits = function(client_id, text_edits, from, to)
  if text_edits == nil then return from, to end

  local cur       = vim.api.nvim_win_get_cursor(0)
  local cursor_id = vim.api.nvim_buf_set_extmark(0, H.ns_id, cur[1] - 1,  cur[2],  {})
  local from_id   = vim.api.nvim_buf_set_extmark(0, H.ns_id, from[1] - 1, from[2], {})
  local to_id     = vim.api.nvim_buf_set_extmark(0, H.ns_id, to[1] - 1,   to[2],   {})

  H.apply_text_edits(client_id, text_edits)

  local cd = H.del_extmark(cursor_id)
  pcall(vim.api.nvim_win_set_cursor, 0, { cd[1] + 1, cd[2] })

  local fd = H.del_extmark(from_id)
  local td = H.del_extmark(to_id)
  return { fd[1] + 1, fd[2] }, { td[1] + 1, td[2] }
end

-- Utilities ------------------------------------------------------------------
H.pumvisible      = function() return vim.fn.pumvisible() > 0 end
H.is_valid_win    = function(w) return type(w) == "number" and vim.api.nvim_win_is_valid(w) end
H.is_char_keyword = function(c) return vim.fn.match(c, "[[:keyword:]]") >= 0 end

H.get_left_char = function()
  local line = vim.api.nvim_get_current_line()
  local col  = vim.api.nvim_win_get_cursor(0)[2]
  return string.sub(line, col, col)
end

H.table_get = function(t, id)
  if type(id) ~= "table" then return H.table_get(t, { id }) end
  local ok, res = true, t
  for _, i in ipairs(id) do
    ok, res = pcall(function() return res[i] end)
    if not ok or res == nil then return nil end
  end
  return res
end

H.del_extmark = function(extmark_id, with_text)
  local data    = vim.api.nvim_buf_get_extmark_by_id(0, H.ns_id, extmark_id, { details = true })
  vim.api.nvim_buf_del_extmark(0, H.ns_id, extmark_id)
  local details = data[3] --[[@as any]]
  if not with_text or data[1] == nil or details.end_row == nil then return data end
  local sr, sc = data[1] --[[@as integer]], data[2] --[[@as integer]]
  local er, ec = details.end_row --[[@as integer]], details.end_col --[[@as integer]]
  if sr < er or (sr == er and sc < ec) then
    vim.api.nvim_buf_set_text(0, sr, sc, er, ec, { "" })
  end
  return data
end

H.get_completion_range = function(lsp_result)
  local pos = vim.api.nvim_win_get_cursor(0)
  for _, rd in pairs(lsp_result or {}) do
    local range = H.get_lsp_edit_range(rd)
    if range then return { range.start.line + 1, range.start.character }, pos end
  end
  local line = vim.api.nvim_get_current_line()
  return { pos[1], vim.fn.match(line:sub(1, pos[2]), "\\k*$") }, pos
end

H.get_lsp_edit_range = function(rd)
  if rd.err or rd.error or type(rd.result) ~= "table" then return end
  local er = H.table_get(rd.result, { "itemDefaults", "editRange" })
  if type(er) == "table" then return er.insert or er end
  local items = rd.result.items or rd.result
  for _, item in ipairs(items) do
    if type(item.textEdit) == "table" then return item.textEdit.range or item.textEdit.insert end
  end
end

H.make_position_params = function(context)
  local res = vim.lsp.util.make_position_params(0, "utf-16") --[[@as any]]
  res.context = context
  return res
end
if vim.fn.has("nvim-0.11") == 1 then
  H.make_position_params = function(context)
    return function(client, _)
      local res = vim.lsp.util.make_position_params(0, client.offset_encoding) --[[@as any]]
      res.context = context
      return res
    end
  end
end

H.client_request = function(client, method, params, handler, bufnr)
  local ok, req_id = client:request(method, params, handler, bufnr)
  return ok and function() pcall(client.cancel_request, client, req_id) end or function() end
end

-- Public API -----------------------------------------------------------------

--- Two-stage LSP → fallback completion function. Set as completefunc/omnifunc.
M.completefunc_lsp = function(findstart, base)
  if not H.has_lsp_clients("completionProvider") or H.completion.lsp.status == "sent" then
    return findstart == 1 and -3 or {}
  end

  if H.completion.lsp.status ~= "received" then
    H.make_completion_request()
    return findstart == 1 and -3 or {}
  end

  if findstart == 1 then
    local from, to = H.get_completion_range(H.completion.lsp.result)
    H.completion.init_base = { lnum = from[1], col = from[2], length = math.max(to[2] - from[2], 0) }
    return from[2]
  end

  local is_incomplete = false
  local all_items = H.process_lsp_response(H.completion.lsp.result, function(response, client_id)
    is_incomplete = is_incomplete or (response.isIncomplete == true)
    local items   = H.table_get(response, { "items" }) or response
    if type(items) ~= "table" then return {} end
    items = H.apply_item_defaults(items, response.itemDefaults)
    for _, item in ipairs(items) do item.client_id = client_id end
    return items
  end)

  local process   = H.get_config().lsp_completion.process_items or M.default_process_items
  all_items       = process(all_items, base)
  local candidates = H.lsp_items_to_complete_items(all_items)

  H.completion.lsp.status       = "done"
  H.completion.lsp.is_incomplete = is_incomplete

  if vim.tbl_isempty(candidates) and H.completion.fallback then
    return H.trigger_fallback()
  end

  H.completion.source = "lsp"
  return candidates
end

--- Filter and sort LSP completion items.
---@param items table
---@param base string
---@param opts? { filtersort?: "prefix"|"fuzzy"|"none"|function, kind_priority?: table }
---@return table
M.default_process_items = function(items, base, opts)
  opts = opts or {}
  local fs = opts.filtersort or (vim.o.completeopt:find("fuzzy") ~= nil and "fuzzy" or "prefix")

  local methods = {
    prefix = function(it, b)
      local res = vim.tbl_filter(function(x) return vim.startswith(H.lsp_filterword(x), b) end, it)
      res = vim.deepcopy(res)
      table.sort(res, H.lsp_item_compare)
      return res
    end,
    fuzzy = function(it, b)
      if b == "" then return vim.deepcopy(it) end
      return vim.fn.matchfuzzy(it, b, { text_cb = H.lsp_filterword })
    end,
    none = function(it, _) return vim.deepcopy(it) end,
  }

  local fn = type(fs) == "string" and methods[fs] or fs
  if not vim.is_callable(fn) then
    error("(keystone.complete) `filtersort` must be 'prefix', 'fuzzy', 'none', or callable", 0)
  end
  local res = fn(items, base)
  if opts.kind_priority then res = H.lsp_arrange_by_kind(res, opts.kind_priority) end
  H.add_item_hlgroups(res)
  return res
end

--- Insert a snippet at cursor.
---@param snippet string
M.default_snippet_insert = function(snippet)
  if vim.fn.has("nvim-0.10") == 1 then return vim.snippet.expand(snippet) end
  local pos   = vim.api.nvim_win_get_cursor(0)
  local lines = vim.split(snippet, "\n")
  vim.api.nvim_buf_set_text(0, pos[1] - 1, pos[2], pos[1] - 1, pos[2], lines)
  local n     = #lines
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
          valueSet = { 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25 },
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

--- Force two-stage completion.
M.complete_twostage = function(fallback, force)
  if fallback == nil then fallback = true end
  if force   == nil then force   = true end
  H.stop_completion()
  H.completion.fallback, H.completion.force = fallback, force
  H.trigger_twostep()
end

--- Force fallback completion.
M.complete_fallback = function()
  H.stop_completion()
  H.completion.fallback, H.completion.force = true, true
  H.trigger_fallback()
end

--- Stop completion.
M.stop = function()
  H.stop_completion()
end

---@param opts keystone.complete.Config?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

  H.create_default_hl()

  if M.config.enabled then
    H.apply_config(M.config)
    H.create_autocommands(M.config)
  end
end

return M
