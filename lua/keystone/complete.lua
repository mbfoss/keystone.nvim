local M = {}

local itemutil = require("keystone.complete.items")

---@class keystone.complete.LspConfig
---@field source_func "completefunc"|"omnifunc"
---@field auto_setup boolean
---@field process_items? fun(items: table, base: string): table
---@field snippet_insert? fun(snippet: string)

---@class keystone.complete.Config
---@field enabled boolean
---@field delay integer
---@field lsp_completion keystone.complete.LspConfig
---@field key string
---@field tab_completion boolean
---@field source_order (string[])|fun() Completion sources tried in order; the first available one fires (LSP is not special -- it is just the "completefunc"/"omnifunc" slot `lsp_completion` claims). An unavailable slot is skipped, so fallback is automatic. Each entry is a named option-backed source ("completefunc"/"omnifunc") or literal insert-mode keys for any other ins-completion submode, e.g. "<C-x><C-n>" buffer words, "<C-x><C-f>" files.

---@return keystone.complete.Config
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
    key             = "<C-Space>",

  -- use <Tab>/<S-Tab> to accept the selected item, VSCode-style; falls back to the keys' normal action when no menu is open
    tab_completion  = true,

    -- Completion sources, tried in order; the first available one fires. Nothing
    -- here is special-cased for LSP: it is simply whichever "completefunc"/
    -- "omnifunc" slot `lsp_completion` claims, and those named slots fire even
    -- when owned by an ftplugin rather than this module. A slot with no source
    -- (empty, or an LSP slot with no client) is skipped, so the next entry is
    -- used automatically -- fallback needs no configuration. Any other entry is
    -- literal insert-mode keys, e.g. "<C-x><C-n>" to append current-buffer
    -- keyword completion at the end of the chain.
    source_order    = { "completefunc", "omnifunc" },
  }
end

M.config = default_config()

-- State ----------------------------------------------------------------------

local _ns = vim.api.nvim_create_namespace("keystone_complete")

--- The two option-backed sources, named because they carry an availability
--- check (empty slot / no LSP client). Every other ins-completion submode is
--- written as raw keys in `source_order`, e.g. "<C-x><C-n>" buffer, "<C-x><C-f>"
--- files. Values are the raw keys; termcodes are replaced when fed.
local _slot_keys = {
  completefunc = "<C-x><C-u>",
  omnifunc     = "<C-x><C-o>",
}

--- Resolved keys -> backing option, for the availability check.
local _opt_of = {}
for opt, keys in pairs(_slot_keys) do
  _opt_of[vim.api.nvim_replace_termcodes(keys, true, false, true)] = opt
end

--- Keystrokes for navigating an open popup menu.
local _nav_keys = {
  select_next = vim.api.nvim_replace_termcodes("<C-n>", true, false, true),
  select_prev = vim.api.nvim_replace_termcodes("<C-p>", true, false, true),
}

--- Value written to 'completefunc'/'omnifunc' when this module owns the slot.
local _lsp_func = "v:lua.require'keystone.complete'.completefunc_lsp"

local _has_native_snippet = vim.fn.has("nvim-0.10") == 1

local _change_tick = 0

---@class keystone.complete.LspState
---@field id integer
---@field status? "sent"|"received"|"done"|"canceled"
---@field is_incomplete boolean
---@field result? table
---@field resolved table<integer, table>
---@field cancel_fn? function
---@field context? table
---@field slot? string resolved keys of the source that fired the request, replayed on response

---@class keystone.complete.State
---@field force boolean
---@field source? string
---@field tick integer
---@field timer uv.uv_timer_t?
---@field lsp keystone.complete.LspState
---@field init_base { lnum?: integer, col?: integer, length?: integer }

---@type keystone.complete.State
local _state = {
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
    slot          = nil,
  },
  init_base = { lnum = nil, col = nil, length = nil },
}

---@type integer? floating documentation window
local _doc_win

-- Utilities ------------------------------------------------------------------

---@return keystone.complete.Config
local function get_config()
  local override = vim.b.keystone_complete_config
  if override == nil then return M.config end
  return vim.tbl_deep_extend("force", M.config, override)
end

---@return boolean
local function pumvisible() return vim.fn.pumvisible() > 0 end

---@param c string
---@return boolean
local function is_keyword(c) return vim.fn.match(c, "[[:keyword:]]") >= 0 end

---@return string
local function get_left_char()
  local line = vim.api.nvim_get_current_line()
  local col  = vim.api.nvim_win_get_cursor(0)[2]
  return string.sub(line, col, col)
end

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
---@param kind "completion"|"signature"
---@return boolean
local function is_trigger_char(char, kind)
  local providers = { completion = "completionProvider", signature = "signatureHelpProvider" }
  for _, client in ipairs(clients_with(providers[kind])) do
    local triggers = vim.tbl_get(client.server_capabilities, providers[kind], "triggerCharacters")
    if vim.tbl_contains(triggers or {}, char) then return true end
  end
  return false
end

local function cancel_lsp()
  if vim.tbl_contains({ "sent", "received" }, _state.lsp.status) then
    if _state.lsp.cancel_fn then _state.lsp.cancel_fn() end
    _state.lsp.status = "canceled"
  end
  _state.lsp.result, _state.lsp.cancel_fn = nil, nil
end

---@param id integer
---@return boolean
local function lsp_request_current(id)
  return _state.lsp.id == id and _state.lsp.status == "sent"
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

-- Completion flow ------------------------------------------------------------

---@param keep_source? boolean
---@param keep_lsp_incomplete? boolean
---@param keep_lsp_resolved? boolean
local function stop_completion(keep_source, keep_lsp_incomplete, keep_lsp_resolved)
  _state.timer:stop()
  cancel_lsp()
  _state.lsp.context = nil
  _state.force = false
  if not keep_source then _state.source = nil end
  if not keep_lsp_incomplete then _state.lsp.is_incomplete = false end
  if not keep_lsp_resolved then _state.lsp.resolved = {} end
end

--- Whether the source for `keys` can be triggered now. A source is used when it
--- exists, regardless of whether it will return any items. Raw-key sources are
--- always ready; for the option-backed completefunc/omnifunc the option must be
--- set, and when the slot holds this module's own LSP function it exists only
--- while there are LSP completion clients, so an empty LSP slot falls through to
--- the next source instead of dead-ending here.
---@param keys string resolved (termcode-replaced) insert-mode keys
---@return boolean
local function source_available(keys)
  local opt = _opt_of[keys]
  if opt == nil then return true end
  local cur = vim.bo[opt]
  if cur == "" then return false end
  if cur == _lsp_func then return has_lsp_clients("completionProvider") end
  return true
end

local function request_completion()
  cancel_lsp() -- keep a single request in flight even if a caller skips the guard
  local req_id        = _state.lsp.id + 1
  _state.lsp.id        = req_id
  _state.lsp.status    = "sent"

  local ctx           = _state.lsp.context or { triggerKind = vim.lsp.protocol.CompletionTriggerKind.Invoked }
  local buf_id        = vim.api.nvim_get_current_buf()

  _state.lsp.cancel_fn = vim.lsp.buf_request_all(buf_id, "textDocument/completion", position_params(ctx),
    function(result)
      if not lsp_request_current(req_id) then return end
      _state.lsp.status = "received"
      _state.lsp.result = result
      -- Re-feed the slot that fired the request so completefunc_lsp re-enters
      -- and returns items now that the response is in.
      if vim.fn.mode() == "i" and not (pumvisible() and not _state.force) then
        local keys = _state.lsp.slot or vim.api.nvim_replace_termcodes(_slot_keys.completefunc, true, false, true)
        vim.api.nvim_feedkeys(keys, "n", false)
      end
    end)
end

--- Trigger the first available source in `source_order`, in the configured
--- order with no priority given to the LSP slot. Replaces the old auto / lsp /
--- fallback split: LSP is just whichever completefunc/omnifunc slot holds our
--- function, reached only at its position in the list.
local function trigger_auto()
  if vim.fn.mode() ~= "i" or (pumvisible() and not _state.force) then return end
  if not (_state.force or _state.tick == _change_tick) then return end

  local order = get_config().source_order
  if vim.is_callable(order) then return order() end
  if type(order) ~= "table" then return end

  for _, entry in ipairs(order) do
    local keys = vim.api.nvim_replace_termcodes(_slot_keys[entry] or entry, true, false, true)
    if source_available(keys) then
      _state.lsp.slot = keys
      vim.api.nvim_feedkeys(keys, "n", false)
      return
    end
  end
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
  local item = _state.lsp.resolved[lsp_data.item_id] or lsp_data.item
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

    local insert = get_config().lsp_completion.snippet_insert or M.default_snippet_insert
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

  local item = _state.lsp.resolved[lsp_data.item_id] or lsp_data.item
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
    _state.lsp.resolved[item_id] = result
    vim.schedule(function()
      if not pumvisible() then return end
      local cur_item = selected_completed_item()
      local cur = cur_item and vim.tbl_get(cur_item, "user_data", "lsp")
      if cur and cur.item_id == item_id then show_doc_content(result.documentation) end
    end)
  end, vim.api.nvim_get_current_buf())
end

local function show_signature_help()
  if in_float() then return end
  local client = clients_with("signatureHelpProvider")[1]
  if not client then return end
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  client:request("textDocument/signatureHelp", params, function(err, result, ctx)
    if err or not result or not result.signatures or #result.signatures == 0 then return end
    for _, sig in ipairs(result.signatures) do
      sig.documentation = nil
    end
    vim.lsp.handlers["textDocument/signatureHelp"](err, result, ctx, {
      silent    = true,
      border    = "rounded",
      focusable = false,
    })
  end, 0)
end

-- Autocommand callbacks ------------------------------------------------------

local function on_insert_char()
  if in_float() then return end
  local cfg = get_config()
  if not cfg.enabled then return end
  _state.timer:stop()

  local is_incomplete = _state.lsp.is_incomplete
  local is_trigger    = is_trigger_char(vim.v.char, "completion")
  local force         = is_trigger or is_incomplete

  if force then
    stop_completion(false, is_incomplete)
  elseif pumvisible() then
    return stop_completion(true, false, true)
  elseif not is_keyword(vim.v.char) then
    return stop_completion(false)
  end

  _state.force = force
  _state.tick = _change_tick + 1

  local kind_name = is_trigger and "TriggerCharacter"
      or (is_incomplete and "TriggerForIncompleteCompletions" or "Invoked")
  _state.lsp.context = {
    triggerKind      = vim.lsp.protocol.CompletionTriggerKind[kind_name],
    triggerCharacter = kind_name == "TriggerCharacter" and vim.v.char or nil,
  }

  local delay = is_incomplete and 0 or cfg.delay
  _state.timer:start(delay, 0, vim.schedule_wrap(trigger_auto))
end

local function on_cursor_moved()
  show_signature_help()
end

local function on_complete_done()
  if _state.lsp.status == "received" then return end
  local lsp_data = vim.tbl_get(vim.v.completed_item, "user_data", "lsp")
  if lsp_data ~= nil then apply_completion_extras(lsp_data) end
  M.stop()
end

-- Setup ----------------------------------------------------------------------

local function setup_hl()
  vim.api.nvim_set_hl(0, "KeystoneCompletionDeprecated", { default = true, link = "DiagnosticDeprecated" })
end

---@param config keystone.complete.Config
local function apply_config(config)
  ---@param lhs string
  ---@param rhs function
  ---@param opts? table
  local function map(lhs, rhs, opts)
    if lhs == "" then return end
    vim.keymap.set("i", lhs, rhs, vim.tbl_extend("force", { silent = true }, opts or {}))
  end

  map(config.key, M.complete, { desc = "Complete with two-stage" })
  if config.tab_completion then
    map("<Tab>", function() M.confirm("<Tab>", 1) end, { desc = "Confirm completion" })
    map("<S-Tab>", function() M.confirm("<S-Tab>", -1) end, { desc = "Confirm completion (previous item)" })
  end

  ---@param opt string
  ---@param val fun()
  local function set_if_unset(opt, val)
    if not vim.api.nvim_get_option_info2(opt, { scope = "global" }).was_set then val() end
  end
  set_if_unset("completeopt", function() vim.o.completeopt = "menuone,noselect" end)
  set_if_unset("shortmess", function() vim.opt.shortmess:append("c") end)
end

---@param config keystone.complete.Config
local function setup_autocmds(config)
  local gr = vim.api.nvim_create_augroup("keystone_complete", { clear = true })
  ---@param event string|string[]
  ---@param pattern string
  ---@param cb function
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
  au("TextChangedI", "*", function() _change_tick = _change_tick + 1 end)
  au("TextChangedP", "*", function() _change_tick = _change_tick + 1 end)

  if config.lsp_completion.auto_setup then
    -- Read config live so a per-buffer `source_func`/`enabled` is honored, and
    -- leave the slot alone when a filetype plugin or the user already owns it.
    au("BufEnter", "*", function()
      local cfg = get_config()
      if not cfg.enabled then return end
      local sf  = cfg.lsp_completion.source_func
      local cur = vim.bo[sf]
      if cur == "" or cur == _lsp_func then vim.bo[sf] = _lsp_func end
    end)
  end
end

-- Public API -----------------------------------------------------------------

--- Two-stage LSP → fallback completion function. Set as completefunc/omnifunc.
---@param findstart 0|1
---@param base string
---@return integer|table|nil
M.completefunc_lsp = function(findstart, base)
  if not has_lsp_clients("completionProvider") or _state.lsp.status == "sent" then
    return findstart == 1 and -3 or {}
  end

  if _state.lsp.status ~= "received" then
    request_completion()
    return findstart == 1 and -3 or {}
  end

  if findstart == 1 then
    local from, to = completion_range(_state.lsp.result)
    _state.init_base = { lnum = from[1], col = from[2], length = math.max(to[2] - from[2], 0) }
    return from[2]
  end

  local is_incomplete     = false
  local all_items         = collect_lsp_results(_state.lsp.result, function(response, client_id)
    is_incomplete = is_incomplete or (response.isIncomplete == true)
    local items   = response.items or response
    if type(items) ~= "table" then return {} end
    items = itemutil.apply_defaults(items, response.itemDefaults)
    for _, item in ipairs(items) do item.client_id = client_id end
    return items
  end)

  local process           = get_config().lsp_completion.process_items or M.default_process_items
  all_items               = process(all_items, base)
  local candidates        = itemutil.to_vim(all_items)

  _state.lsp.status        = "done"
  _state.lsp.is_incomplete = is_incomplete

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

--- Force two-stage completion.
---@param force? boolean
M.complete = function(force)
  if not get_config().enabled then return end
  if force == nil then force = true end
  stop_completion()
  _state.force = force
  trigger_auto()
end

--- Stop completion.
M.stop = function()
  stop_completion()
end

--- Accept the highlighted completion entry, selecting the first (or last, if
--- `direction` is -1) one if none is highlighted yet. If no completion menu is
--- open, jumps to the next (or previous) snippet placeholder when one is
--- active, otherwise sends `fallback_keys` -- so the same key can be mapped
--- for VSCode-style Tab/S-Tab-to-accept behavior without breaking native
--- snippet navigation.
---@param fallback_keys string
---@param direction? 1|-1
M.confirm = function(fallback_keys, direction)
  direction = direction == -1 and -1 or 1
  if pumvisible() then
    vim.api.nvim_feedkeys(direction == -1 and _nav_keys.select_prev or _nav_keys.select_next, "n", false)
    return
  end
  if _has_native_snippet and vim.snippet.active({ direction = direction }) then
    return vim.snippet.jump(direction)
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(fallback_keys, true, false, true), "n", false)
end

---@param opts keystone.complete.Config?
M.setup = function(opts)
  M.config = vim.tbl_deep_extend("force", default_config(), opts or {})
  setup_hl()
  if M.config.enabled then
    apply_config(M.config)
    setup_autocmds(M.config)
  end
end

return M
