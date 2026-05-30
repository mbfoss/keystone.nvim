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

local function default_config()
  ---@type keystone.complete.Config
  return {
    enabled         = true,
    delay           = 100,
    lsp_completion  = {
      source_func    = "completefunc",
      auto_setup     = true,
      process_items  = nil,
      snippet_insert = nil,
    },
    fallback_action = "", -- "<C-n>",
    mappings        = {
      force_twostep  = "<C-Space>",
      force_fallback = "<A-Space>",
    },
  }
end

M.config = default_config()

-- State ----------------------------------------------------------------------

local ns = vim.api.nvim_create_namespace("keystone_complete")

local keys = {
  completefunc = vim.api.nvim_replace_termcodes("<C-x><C-u>", true, false, true),
  omnifunc     = vim.api.nvim_replace_termcodes("<C-x><C-o>", true, false, true),
  ctrl_n       = vim.api.nvim_replace_termcodes("<C-g><C-g><C-n>", true, false, true),
}

local change_tick = 0

local state = {
  fallback  = true,
  force     = false,
  source    = nil,
  tick      = 0,
  timer     = vim.uv.new_timer(),
  lsp       = {
    id            = 0,
    status        = nil,
    is_incomplete = false,
    result        = nil,
    resolved      = {},
    cancel_fn     = nil,
    context       = nil,
  },
  init_base = { lnum = nil, col = nil, length = nil },
}

local kind_map -- lazily built by build_kind_map()
local doc_win  -- floating documentation window

-- Utilities ------------------------------------------------------------------

local function get_config()
  return vim.tbl_deep_extend("force", M.config, vim.b.keystone_complete_config or {})
end

local function pumvisible() return vim.fn.pumvisible() > 0 end
local function is_keyword(c) return vim.fn.match(c, "[[:keyword:]]") >= 0 end

local function get_left_char()
  local line = vim.api.nvim_get_current_line()
  local col  = vim.api.nvim_win_get_cursor(0)[2]
  return string.sub(line, col, col)
end

local function in_float()
  return vim.api.nvim_win_get_config(0).relative ~= ""
end

local function tbl_get(t, id)
  if type(id) ~= "table" then return tbl_get(t, { id }) end
  local ok, res = true, t
  for _, i in ipairs(id) do
    ok, res = pcall(function() return res[i] end)
    if not ok or res == nil then return nil end
  end
  return res
end

local function pop_extmark(id, delete_text)
  local data = vim.api.nvim_buf_get_extmark_by_id(0, ns, id, { details = true })
  vim.api.nvim_buf_del_extmark(0, ns, id)
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

local function has_lsp_clients(capability)
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if vim.tbl_isempty(clients) then return false end
  if not capability then return true end
  for _, c in pairs(clients) do
    if tbl_get(c.server_capabilities, capability) then return true end
  end
  return false
end

local function lsp_func_set()
  local sf = get_config().lsp_completion.source_func
  return vim.bo[sf] == "v:lua.require'keystone.complete'.completefunc_lsp"
end

local function is_trigger_char(char, kind)
  local providers = { completion = "completionProvider", signature = "signatureHelpProvider" }
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
    local triggers = tbl_get(client, { "server_capabilities", providers[kind], "triggerCharacters" })
    if vim.tbl_contains(triggers or {}, char) then return true end
  end
  return false
end

local function cancel_lsp()
  if vim.tbl_contains({ "sent", "received" }, state.lsp.status) then
    if state.lsp.cancel_fn then state.lsp.cancel_fn() end
    state.lsp.status = "canceled"
  end
  state.lsp.result, state.lsp.cancel_fn = nil, nil
end

local function lsp_request_current(id)
  return state.lsp.id == id and state.lsp.status == "sent"
end

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

local function lsp_edit_range(rd)
  if rd.err or rd.error or type(rd.result) ~= "table" then return end
  local er = tbl_get(rd.result, { "itemDefaults", "editRange" })
  if type(er) == "table" then return er.insert or er end
  local items = rd.result.items or rd.result
  for _, item in ipairs(items) do
    if type(item.textEdit) == "table" then return item.textEdit.range or item.textEdit.insert end
  end
end

local function completion_range(lsp_result)
  local pos = vim.api.nvim_win_get_cursor(0)
  for _, rd in pairs(lsp_result or {}) do
    local range = lsp_edit_range(rd)
    if range then return { range.start.line + 1, range.start.character }, pos end
  end
  local line = vim.api.nvim_get_current_line()
  return { pos[1], vim.fn.match(line:sub(1, pos[2]), "\\k*$") }, pos
end

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

-- Item processing ------------------------------------------------------------

local function lsp_filter_word(x) return x.filterText or x.label end
local function lsp_word(item)
  return tbl_get(item, { "textEdit", "newText" }) or item.insertText or lsp_filter_word(item) or ""
end

local function apply_defaults(items, defaults)
  if type(defaults) ~= "table" then return items end
  local er, has_er = defaults.editRange, type(defaults.editRange) == "table"
  local er_range   = (er or {}).start ~= nil and er or nil
  for _, item in ipairs(items) do
    item.commitCharacters = item.commitCharacters or defaults.commitCharacters
    item.data             = item.data or defaults.data
    item.insertTextFormat = item.insertTextFormat or defaults.insertTextFormat
    item.insertTextMode   = item.insertTextMode or defaults.insertTextMode
    if has_er then
      item.textEdit         = item.textEdit or {}
      item.textEdit.newText = item.textEdit.newText or item.textEditText or item.label
      item.textEdit.range   = item.textEdit.range or er_range
      item.textEdit.insert  = item.textEdit.insert or er.insert
      item.textEdit.replace = item.textEdit.replace or er.replace
    end
  end
  return items
end

local function to_vim_items(items)
  if vim.tbl_count(items) == 0 then return {} end

  local res        = {}
  local item_kinds = vim.lsp.protocol.CompletionItemKind
  local snip_kind  = vim.lsp.protocol.CompletionItemKind.Snippet
  local snip_fmt   = vim.lsp.protocol.InsertTextFormat.Snippet

  for i, item in ipairs(items) do
    local word         = lsp_word(item)
    local is_sk        = item.kind == snip_kind
    local is_sf        = item.insertTextFormat == snip_fmt
    local snip_body    = (word:find("[^\\]%${?%w") or word:find("^%${?%w") or word:find("[\n\t]")) ~= nil
    local is_snippet   = (is_sk or is_sf) and snip_body

    local details      = item.labelDetails or {}
    local sm           = is_snippet and "S" or ""
    local detail, desc = details.detail or "", details.description or ""
    local menu         = sm .. ((sm ~= "" and detail ~= "") and " " or "") .. detail
    menu               = menu .. ((menu ~= "" and desc ~= "") and " " or "") .. desc

    table.insert(res, {
      word = is_snippet and lsp_filter_word(item) or word,
      abbr = item.label,
      abbr_hlgroup = item.abbr_hlgroup,
      kind = item_kinds[item.kind] or "Unknown",
      kind_hlgroup = item.kind_hlgroup,
      menu = menu,
      info = is_snippet and word or nil,
      icase = 1,
      dup = 1,
      empty = 1,
      user_data = { lsp = { item = item, item_id = i, needs_snippet_insert = is_snippet } },
    })
  end
  return res
end

local function build_kind_map()
  if kind_map then return end
  kind_map = {}
  for k, v in pairs(vim.lsp.protocol.CompletionItemKind) do
    if type(k) == "string" and type(v) == "number" then kind_map[v] = k end
  end
end

local function sort_by_kind(items, kind_priority)
  build_kind_map()
  local raw = {}
  for i, item in ipairs(items) do
    local priority = kind_priority[kind_map[item.kind]] or 100
    if priority >= 0 then table.insert(raw, { priority, i, item }) end
  end
  table.sort(raw, function(a, b) return a[1] > b[1] or (a[1] == b[1] and a[2] < b[2]) end)
  return vim.tbl_map(function(x) return x[3] end, raw)
end

local function add_hlgroups(items)
  local deprecated_tag = vim.lsp.protocol.CompletionTag.Deprecated
  for _, item in ipairs(items) do
    local deprecated = item.deprecated
        or (item.tags and vim.list_contains(item.tags, deprecated_tag))
    item.abbr_hlgroup = item.abbr_hlgroup
        or (deprecated and "KeystoneCompletionDeprecated" or nil)
  end
  return items
end

-- Completion flow ------------------------------------------------------------

local function stop_completion(keep_source, keep_lsp_incomplete, keep_lsp_resolved)
  state.timer:stop()
  cancel_lsp()
  state.lsp.context = nil
  state.fallback, state.force = true, false
  if not keep_source then state.source = nil end
  if not keep_lsp_incomplete then state.lsp.is_incomplete = false end
  if not keep_lsp_resolved then state.lsp.resolved = {} end
end

local function trigger_fallback()
  if (pumvisible() and not state.force) or vim.fn.mode() ~= "i" then return end
  state.source = "fallback"
  local action = get_config().fallback_action
  if vim.is_callable(action) then return action() end
  if type(action) ~= "string" then return end
  if action == "<C-n>" then
    vim.api.nvim_feedkeys(keys.ctrl_n, "n", false)
    return
  end
  if action ~= "" then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-g><C-g>" .. action, true, false, true), "n", false)
  end
end

-- forward declaration: request_completion and trigger_lsp mutually reference each other
local trigger_lsp

local function request_completion()
  local req_id        = state.lsp.id + 1
  state.lsp.id        = req_id
  state.lsp.status    = "sent"

  local ctx           = state.lsp.context or { triggerKind = vim.lsp.protocol.CompletionTriggerKind.Invoked }
  local buf_id        = vim.api.nvim_get_current_buf()

  state.lsp.cancel_fn = vim.lsp.buf_request_all(buf_id, "textDocument/completion", position_params(ctx),
    function(result)
      if not lsp_request_current(req_id) then return end
      state.lsp.status = "received"
      state.lsp.result = result
      trigger_lsp()
    end)
end

trigger_lsp = function()
  if vim.fn.mode() ~= "i" or (pumvisible() and not state.force) then return end
  if state.lsp.status ~= "received" then return request_completion() end
  vim.api.nvim_feedkeys(keys[get_config().lsp_completion.source_func], "n", false)
end

local function trigger_auto()
  local allow = vim.fn.mode() == "i" and (state.force or state.tick == change_tick)
  if not allow then return end
  if has_lsp_clients("completionProvider") and lsp_func_set() then
    trigger_lsp()
  elseif state.fallback then
    trigger_fallback()
  end
end

-- LSP extra actions (snippet insert, additional text edits, commands) --------

local function apply_text_edits(client_id, text_edits)
  if text_edits == nil then return end
  local enc = client_id and vim.lsp.get_client_by_id(client_id).offset_encoding or "utf-16"
  vim.lsp.util.apply_text_edits(text_edits, vim.api.nvim_get_current_buf(), enc)
end

local function exec_command(client_id, command)
  if command == nil or client_id == nil then return end
  local client = vim.lsp.get_client_by_id(client_id)
  if client and client.exec_cmd then
    client:exec_cmd(command, { bufnr = vim.api.nvim_get_current_buf() })
  end
end

local function tracked_text_edits(client_id, text_edits, from, to)
  if text_edits == nil then return from, to end

  local cur       = vim.api.nvim_win_get_cursor(0)
  local cursor_id = vim.api.nvim_buf_set_extmark(0, ns, cur[1] - 1, cur[2], {})
  local from_id   = vim.api.nvim_buf_set_extmark(0, ns, from[1] - 1, from[2], {})
  local to_id     = vim.api.nvim_buf_set_extmark(0, ns, to[1] - 1, to[2], {})

  apply_text_edits(client_id, text_edits)

  local cd = pop_extmark(cursor_id)
  pcall(vim.api.nvim_win_set_cursor, 0, { cd[1] + 1, cd[2] })

  local fd = pop_extmark(from_id)
  local td = pop_extmark(to_id)
  return { fd[1] + 1, fd[2] }, { td[1] + 1, td[2] }
end

local function apply_completion_extras(lsp_data)
  local item = state.lsp.resolved[lsp_data.item_id] or lsp_data.item
  if item.additionalTextEdits == nil and item.command == nil and not lsp_data.needs_snippet_insert then return end
  local snippet  = lsp_data.needs_snippet_insert and lsp_word(item) or nil

  local cur      = vim.api.nvim_win_get_cursor(0)
  local track_id = vim.api.nvim_buf_set_extmark(0, ns, cur[1] - 1, cur[2], {
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

    local ib   = state.init_base
    local from = { ib.lnum, ib.col }
    local to   = vim.api.nvim_win_get_cursor(0)
    pcall(vim.api.nvim_buf_set_text, 0, from[1] - 1, from[2], to[1] - 1, to[2],
      { string.rep("x", ib.length) })
    to = { from[1], from[2] + ib.length }

    local prefix_id = vim.api.nvim_buf_set_extmark(0, ns, from[1] - 1, from[2],
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

    local insert = get_config().lsp_completion.snippet_insert or M.default_snippet_insert
    insert(snippet)
  end)
end

-- Documentation float --------------------------------------------------------

local function close_doc_win()
  if doc_win and vim.api.nvim_win_is_valid(doc_win) then
    vim.api.nvim_win_close(doc_win, true)
  end
  doc_win = nil
end

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
    doc_win         = win
  end)
end

local function on_complete_changed()
  local lsp_data = tbl_get(vim.v.completed_item, { "user_data", "lsp" })
  if not lsp_data then
    show_doc_content(nil); return
  end

  local item = state.lsp.resolved[lsp_data.item_id] or lsp_data.item
  if item.documentation then
    show_doc_content(item.documentation)
    return
  end

  local client = vim.lsp.get_client_by_id(item.client_id)
  if not client or not tbl_get(client, { "server_capabilities", "completionProvider", "resolveProvider" }) then
    show_doc_content(nil)
    return
  end

  local item_id = lsp_data.item_id
  client:request("completionItem/resolve", item, function(err, result)
    if err or not result then return end
    state.lsp.resolved[item_id] = result
    vim.schedule(function()
      if not pumvisible() then return end
      local cur = tbl_get(vim.v.completed_item, { "user_data", "lsp" })
      if cur and cur.item_id == item_id then show_doc_content(result.documentation) end
    end)
  end, vim.api.nvim_get_current_buf())
end

-- Autocommand callbacks ------------------------------------------------------

local function on_insert_char()
  if in_float() then return end
  state.timer:stop()

  local is_incomplete = state.lsp.is_incomplete
  local is_trigger    = is_trigger_char(vim.v.char, "completion")
  local force         = is_trigger or is_incomplete

  if force then
    stop_completion(false, is_incomplete)
  elseif pumvisible() then
    return stop_completion(true, false, true)
  elseif not is_keyword(vim.v.char) then
    return stop_completion(false)
  end

  state.fallback, state.force = not force, force
  state.tick = change_tick + 1

  if state.source == "lsp" then return trigger_fallback() end

  local kind_name = is_trigger and "TriggerCharacter"
      or (is_incomplete and "TriggerForIncompleteCompletions" or "Invoked")
  state.lsp.context = {
    triggerKind      = vim.lsp.protocol.CompletionTriggerKind[kind_name],
    triggerCharacter = kind_name == "TriggerCharacter" and vim.v.char or nil,
  }

  local delay = is_incomplete and 0 or get_config().delay
  state.timer:start(delay, 0, vim.schedule_wrap(trigger_auto))
end

local function on_cursor_moved()
  if in_float() then return end
  if not has_lsp_clients("signatureHelpProvider") then return end
  ---@type vim.lsp.buf.signature_help.Opts
  local opts = {
    silent = true,
    border = "rounded",
    --close_events = {},
  }
  vim.lsp.buf.signature_help(opts)
end

local function on_complete_done()
  if state.lsp.status == "received" then return end
  local lsp_data = tbl_get(vim.v.completed_item, { "user_data", "lsp" })
  if lsp_data ~= nil then apply_completion_extras(lsp_data) end
  M.stop()
end

-- Setup ----------------------------------------------------------------------

local function setup_hl()
  vim.api.nvim_set_hl(0, "KeystoneCompletionDeprecated", { default = true, link = "DiagnosticDeprecated" })
end

local function apply_config(config)
  local function map(lhs, rhs, opts)
    if lhs == "" then return end
    vim.keymap.set("i", lhs, rhs, vim.tbl_extend("force", { silent = true }, opts or {}))
  end

  map(config.mappings.force_twostep, M.complete_twostage, { desc = "Complete with two-stage" })
  map(config.mappings.force_fallback, M.complete_fallback, { desc = "Complete with fallback" })

  local function set_if_unset(opt, val)
    if not vim.api.nvim_get_option_info2(opt, { scope = "global" }).was_set then val() end
  end
  set_if_unset("completeopt", function() vim.o.completeopt = "menuone,noselect" end)
  set_if_unset("shortmess", function() vim.opt.shortmess:append("c") end)
  if config.fallback_action == "<C-n>" then
    set_if_unset("complete", function() vim.opt.complete:remove("t") end)
  end
end

local function setup_autocmds(config)
  local gr = vim.api.nvim_create_augroup("keystone_complete", { clear = true })
  local function au(event, pattern, cb)
    vim.api.nvim_create_autocmd(event, { group = gr, pattern = pattern, callback = cb })
  end

  au("InsertCharPre", "*", on_insert_char)
  au("CursorMovedI", "*", on_cursor_moved)
  au("CompleteChanged", "*", on_complete_changed)
  au("ModeChanged", "i*:[^i]*", function()
    M.stop(); close_doc_win()
  end)
  au("CompleteDonePre", "*", function()
    close_doc_win(); on_complete_done()
  end)
  au("TextChangedI", "*", function() change_tick = change_tick + 1 end)
  au("TextChangedP", "*", function() change_tick = change_tick + 1 end)

  if config.lsp_completion.auto_setup then
    local sf = config.lsp_completion.source_func
    au("BufEnter", "*", function() vim.bo[sf] = "v:lua.require'keystone.complete'.completefunc_lsp" end)
  end
end

-- Public API -----------------------------------------------------------------

--- Two-stage LSP → fallback completion function. Set as completefunc/omnifunc.
M.completefunc_lsp = function(findstart, base)
  if not has_lsp_clients("completionProvider") or state.lsp.status == "sent" then
    return findstart == 1 and -3 or {}
  end

  if state.lsp.status ~= "received" then
    request_completion()
    return findstart == 1 and -3 or {}
  end

  if findstart == 1 then
    local from, to = completion_range(state.lsp.result)
    state.init_base = { lnum = from[1], col = from[2], length = math.max(to[2] - from[2], 0) }
    return from[2]
  end

  local is_incomplete     = false
  local all_items         = collect_lsp_results(state.lsp.result, function(response, client_id)
    is_incomplete = is_incomplete or (response.isIncomplete == true)
    local items   = tbl_get(response, { "items" }) or response
    if type(items) ~= "table" then return {} end
    items = apply_defaults(items, response.itemDefaults)
    for _, item in ipairs(items) do item.client_id = client_id end
    return items
  end)

  local process           = get_config().lsp_completion.process_items or M.default_process_items
  all_items               = process(all_items, base)
  local candidates        = to_vim_items(all_items)

  state.lsp.status        = "done"
  state.lsp.is_incomplete = is_incomplete

  if vim.tbl_isempty(candidates) and state.fallback then
    return trigger_fallback()
  end

  state.source = "lsp"
  return candidates
end

--- Filter and sort LSP completion items.
---@param items table
---@param base string
---@param opts? { filtersort?: function, kind_priority?: table }
---@return table
M.default_process_items = function(items, base, opts)
  opts = opts or {}
  local res = opts.filtersort and opts.filtersort(items, base) or vim.deepcopy(items)
  if opts.kind_priority then res = sort_by_kind(res, opts.kind_priority) end
  add_hlgroups(res)
  return res
end

--- Insert a snippet at cursor.
---@param snippet string
M.default_snippet_insert = function(snippet)
  if vim.fn.has("nvim-0.10") == 1 then return vim.snippet.expand(snippet) end
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

--- Force two-stage completion.
M.complete_twostage = function(fallback, force)
  if fallback == nil then fallback = true end
  if force == nil then force = true end
  stop_completion()
  state.fallback, state.force = fallback, force
  trigger_auto()
end

--- Force fallback completion.
M.complete_fallback = function()
  stop_completion()
  state.fallback, state.force = true, true
  trigger_fallback()
end

--- Stop completion.
M.stop = function()
  stop_completion()
end

---@param opts keystone.complete.Config?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", default_config(), opts or {})
  setup_hl()
  if M.config.enabled then
    apply_config(M.config)
    setup_autocmds(M.config)
  end
end

return M
