--- keystone.completion
---
--- A generic, source-agnostic completion trigger engine. It decides *when* to
--- complete (autotrigger on keyword/trigger characters, or the manual key) and
--- fires the sources in `source_order` -- typically `omnifunc` first, then any
--- fallback ins-completion submodes. It treats each source as a black box: on
--- Neovim >= 0.11 `omnifunc` is the built-in `vim.lsp.completion`.
--- It also provides `<Tab>`/`<S-Tab>` confirm + snippet navigation.
--- The LSP item lifecycle (snippets, additionalTextEdits, docs) belongs to the
--- source, not here -- with one exception: `commit_on_char` re-runs the source's
--- own commit actions (snippet, additionalTextEdits, resolve, command) when
--- completion is committed by typing a character rather than <C-y>/<CR>.
local M = {}

---@class keystone.completion.Config
---@field enabled boolean
---@field delay integer debounce before autotriggering, in ms
---@field key string manual-trigger mapping (insert mode)
---@field tab_completion boolean map <Tab>/<S-Tab> to confirm/navigate, VSCode-style
---@field cr_confirm boolean map `<CR>` to confirm the current completion candidate (equivalent to <C-y>; can be used to enter snippet mode)
---@field commit_on_char boolean when a completion is committed by typing a following character (e.g. `(`) rather than <C-y>/<CR>, re-run the source's own commit actions -- snippet expansion, additionalTextEdits, resolve, and item command -- which the native source applies only on an explicit accept. A snippet also absorbs the committing char (its expansion supplies its own delimiters); other items keep the char and only gain the extra edits. Needs no key mappings, so it does not clash with autopairs.
---@field source_order (string[])|fun() Sources tried in order; the first available one fires. "omnifunc"/"completefunc" are the named option-backed slots (LSP lives on omnifunc); any other entry is literal insert-mode keys, e.g. "<C-x><C-n>" buffer words.

---@return keystone.completion.Config
local function default_config()
  ---@type keystone.completion.Config
  return {
    enabled        = true,
    delay          = 100,
    key            = "<C-Space>",
    tab_completion = true,
    cr_confirm     = true,
    commit_on_char = true,
    source_order   = { "omnifunc", "completefunc" },
  }
end

M.config = default_config()

-- State ----------------------------------------------------------------------

--- The two option-backed sources, named because they carry an availability
--- check. Every other ins-completion submode is written as raw keys in
--- `source_order`, e.g. "<C-x><C-n>" buffer, "<C-x><C-f>" files. Values are the
--- raw keys; termcodes are replaced when fed.
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

--- Keystrokes used when confirming with `<CR>`.
local _accept_keys = {
  yes    = vim.api.nvim_replace_termcodes("<C-y>", true, false, true),      -- accept the selected entry
  cancel = vim.api.nvim_replace_termcodes("<C-e><CR>", true, false, true),  -- dismiss the menu, then newline
  cr     = vim.api.nvim_replace_termcodes("<CR>", true, false, true),       -- plain newline, no menu open
}

local _has_native_snippet = vim.fn.has("nvim-0.10") == 1

--- LSP `insertTextFormat` value marking an item as a snippet.
local _snippet_format = vim.lsp.protocol.InsertTextFormat.Snippet

--- Namespace for the throwaway extmark that tracks the committing character.
local _ns = vim.api.nvim_create_namespace("keystone_completion")

local _change_tick = 0

---@class keystone.completion.State
---@field force boolean
---@field source? string
---@field tick integer
---@field timer uv.uv_timer_t?

---@type keystone.completion.State
local _state = {
  force  = false,
  source = nil,
  tick   = 0,
  timer  = vim.uv.new_timer(),
}

-- Utilities ------------------------------------------------------------------

---@return keystone.completion.Config
local function get_config()
  local override = vim.b.keystone_completion_config
  if override == nil then return M.config end
  return vim.tbl_deep_extend("force", M.config, override)
end

---@return boolean
local function pumvisible() return vim.fn.pumvisible() > 0 end

---@param c string
---@return boolean
local function is_keyword(c) return vim.fn.match(c, "[[:keyword:]]") >= 0 end

---@return boolean
local function in_float()
  return vim.api.nvim_win_get_config(0).relative ~= ""
end

--- Buffer-attached clients advertising `capability`. Reads core `vim.lsp`, not
--- the keystone LSP source module -- this stays source-agnostic.
---@param capability string
---@return vim.lsp.Client[]
local function clients_with(capability)
  return vim.tbl_filter(function(c)
    return vim.tbl_get(c.server_capabilities, capability) ~= nil
  end, vim.lsp.get_clients({ bufnr = 0 }))
end

---@param capability string
---@return boolean
local function has_lsp_clients(capability)
  return not vim.tbl_isempty(clients_with(capability))
end

--- Whether the just-typed character is a server-declared completion trigger.
---@param char string
---@return boolean
local function is_trigger_char(char)
  for _, client in ipairs(clients_with("completionProvider")) do
    local triggers = vim.tbl_get(client.server_capabilities, "completionProvider", "triggerCharacters")
    if vim.tbl_contains(triggers or {}, char) then return true end
  end
  return false
end

--- Whether a completion entry (a `complete_info().items[]` or `v:completed_item`
--- table) is an LSP snippet. Native LSP items stash the source `lsp.CompletionItem`
--- under `user_data.nvim.lsp`; anything else (buffer words, files, non-LSP
--- sources, or a cancelled/empty item) is treated as not-a-snippet.
---@param item table?
---@return boolean
local function is_snippet_item(item)
  if type(item) ~= "table" or type(item.user_data) ~= "table" then return false end
  local completion_item = vim.tbl_get(item.user_data, "nvim", "lsp", "completion_item")
  return type(completion_item) == "table" and completion_item.insertTextFormat == _snippet_format
end

-- Completion flow ------------------------------------------------------------

---@param keep_source? boolean
local function stop_completion(keep_source)
  _state.timer:stop()
  _state.force = false
  if not keep_source then _state.source = nil end
end

--- Whether the source for `keys` can be triggered now. Raw-key sources are
--- always ready. For the option-backed slots the option must be set; the LSP
--- slot (omnifunc, by this module's convention) additionally needs a completion
--- client, so an LSP-less buffer falls through to the next source.
---@param keys string resolved (termcode-replaced) insert-mode keys
---@return boolean
local function source_available(keys)
  local opt = _opt_of[keys]
  if opt == nil then return true end
  if vim.bo[opt] == "" then return false end
  if opt == "omnifunc" then return has_lsp_clients("completionProvider") end
  return true
end

--- Trigger the first available source in `source_order`.
local function trigger_auto()
  if vim.fn.mode() ~= "i" or (pumvisible() and not _state.force) then return end
  if not (_state.force or _state.tick == _change_tick) then return end

  local order = get_config().source_order
  if vim.is_callable(order) then return order() end
  if type(order) ~= "table" then return end

  for _, entry in ipairs(order) do
    local keys = vim.api.nvim_replace_termcodes(_slot_keys[entry] or entry, true, false, true)
    if source_available(keys) then
      vim.api.nvim_feedkeys(keys, "n", false)
      return
    end
  end
end

--- Reproduce the source's own CompleteDone actions when completion is committed
--- by typing a character rather than <C-y>/<CR>. `vim.lsp.completion` runs those
--- actions -- snippet expansion, additionalTextEdits, resolve, item command --
--- only on CompleteDone with reason "accept"; typing a following char ends
--- completion with a non-accept reason, so the item is left half-applied (plain
--- label plus the typed char). We re-run the same actions here. A snippet also
--- absorbs the committing char (its expansion carries the delimiter) and replaces
--- the label; other items keep their text and only gain the extra edits. Mirrors
--- native's own `on_complete_done` branching (edits / resolve / plain), sitting on
--- top of the source, which still owns the explicit-accept path.
local function on_complete_done()
  if vim.v.event.reason == "accept" then return end -- native handles the accept path fully
  if not get_config().commit_on_char then return end

  local item = vim.v.completed_item
  local data = (type(item) == "table" and type(item.user_data) == "table")
    and vim.tbl_get(item.user_data, "nvim", "lsp") or nil
  if type(data) ~= "table" or type(data.completion_item) ~= "table" then return end -- non-LSP or cancelled
  local completion_item = data.completion_item
  local client = data.client_id and vim.lsp.get_client_by_id(data.client_id) or nil
  if not client then return end

  -- Snippet text (if any) decides whether the committing char is absorbed.
  local snippet
  if is_snippet_item(item) then
    snippet = (completion_item.textEdit and completion_item.textEdit.newText) or completion_item.insertText
  end
  local absorb = type(snippet) == "string" and snippet ~= ""
  local edits = completion_item.additionalTextEdits
  local has_edits = type(edits) == "table" and next(edits) ~= nil
  local resolvable = vim.tbl_get(client.server_capabilities, "completionProvider", "resolveProvider") == true

  -- A plain item with no follow-up actions: leave the word and typed char as-is.
  if not absorb and not has_edits and not resolvable and completion_item.command == nil then return end

  local bufnr = vim.api.nvim_get_current_buf()
  local enc = client.offset_encoding or "utf-16"
  local label_len = #(item.word or "")
  local cur = vim.api.nvim_win_get_cursor(0)
  local row, col = cur[1] - 1, cur[2]
  -- Only snippets absorb the committing char; track it now (it lands right after
  -- this callback) for removal. Other items keep it -- it is meaningful (e.g. `.`).
  local mark = absorb and vim.api.nvim_buf_set_extmark(bufnr, _ns, row, col, {
    end_row = row, end_col = col, right_gravity = false, end_right_gravity = true,
  }) or nil
  local function clear_mark() if mark then vim.api.nvim_buf_del_extmark(bufnr, _ns, mark) end end

  -- clear_word -> apply additionalTextEdits -> expand snippet -> run command,
  -- matching the native accept path's order.
  local function commit(extra_edits, command)
    if vim.fn.mode() ~= "i" then return clear_mark() end
    if absorb then
      local s_row, s_col = row, col
      if mark then
        local m = vim.api.nvim_buf_get_extmark_by_id(bufnr, _ns, mark, { details = true })
        vim.api.nvim_buf_del_extmark(bufnr, _ns, mark)
        if m[3] then
          s_row, s_col = m[1], m[2]
          if m[3].end_row ~= s_row or m[3].end_col ~= s_col then -- remove the committing char(s)
            pcall(vim.api.nvim_buf_set_text, bufnr, s_row, s_col, m[3].end_row, m[3].end_col, {})
          end
        end
      end
      local word_start = math.max(s_col - label_len, 0) -- drop the inserted label
      pcall(vim.api.nvim_buf_set_text, bufnr, s_row, word_start, s_row, s_col, {})
      pcall(vim.api.nvim_win_set_cursor, 0, { s_row + 1, word_start })
    end
    if extra_edits then pcall(vim.lsp.util.apply_text_edits, extra_edits, bufnr, enc) end
    if snippet then vim.snippet.expand(snippet) end
    if command then pcall(function() client:exec_cmd(command, { bufnr = bufnr }) end) end
  end

  vim.schedule(function()
    if vim.fn.mode() ~= "i" then return clear_mark() end
    if has_edits then
      commit(edits, completion_item.command)
    elseif resolvable then
      -- Some servers deliver additionalTextEdits/command only via resolve. Guard on
      -- changedtick so a late reply cannot edit a buffer the user has moved on in.
      local tick = vim.b[bufnr].changedtick
      client:request("completionItem/resolve", completion_item, function(err, result)
        if vim.b[bufnr].changedtick ~= tick then return clear_mark() end
        local resolved = (not err and type(result) == "table") and result or {}
        commit(resolved.additionalTextEdits, resolved.command or completion_item.command)
      end, bufnr)
    else
      commit(nil, completion_item.command)
    end
  end)
end

-- Autocommand callbacks ------------------------------------------------------

local function on_insert_char()
  if in_float() then return end
  local cfg = get_config()
  if not cfg.enabled then return end
  _state.timer:stop()

  local force = is_trigger_char(vim.v.char)
  if not force then
    if pumvisible() then return end -- let the open menu filter as you type
    if not is_keyword(vim.v.char) then return stop_completion() end
  end

  _state.force = force
  _state.tick  = _change_tick + 1
  _state.timer:start(cfg.delay, 0, vim.schedule_wrap(trigger_auto))
end

-- Setup ----------------------------------------------------------------------

---@param config keystone.completion.Config
local function apply_config(config)
  ---@param lhs string
  ---@param rhs function
  ---@param opts? table
  local function map(lhs, rhs, opts)
    if lhs == "" then return end
    vim.keymap.set("i", lhs, rhs, vim.tbl_extend("force", { silent = true }, opts or {}))
  end

  map(config.key, M.complete, { desc = "Trigger completion" })
  if config.tab_completion then
    map("<Tab>", function() M.confirm("<Tab>", 1) end, { desc = "Confirm completion" })
    map("<S-Tab>", function() M.confirm("<S-Tab>", -1) end, { desc = "Confirm completion (previous item)" })
  end
  if config.cr_confirm then
    map("<CR>", M.accept, { desc = "Confirm completion (<CR>)" })
  end

  ---@param opt string
  ---@param val fun()
  local function set_if_unset(opt, val)
    if not vim.api.nvim_get_option_info2(opt, { scope = "global" }).was_set then val() end
  end
  set_if_unset("completeopt", function() vim.o.completeopt = "menuone,noselect" end)
  set_if_unset("shortmess", function() vim.opt.shortmess:append("c") end)
end

local function setup_autocmds()
  local gr = vim.api.nvim_create_augroup("keystone_completion", { clear = true })
  ---@param event string|string[]
  ---@param pattern string
  ---@param cb function
  local function au(event, pattern, cb)
    vim.api.nvim_create_autocmd(event, { group = gr, pattern = pattern, callback = cb })
  end

  au("InsertCharPre", "*", on_insert_char)
  au("ModeChanged", "i*:[^i]*", function() M.stop() end)
  au("CompleteDonePre", "*", function() stop_completion() end)
  au("CompleteDone", "*", on_complete_done)
  au("TextChangedI", "*", function() _change_tick = _change_tick + 1 end)
  au("TextChangedP", "*", function() _change_tick = _change_tick + 1 end)
end

-- Public API -----------------------------------------------------------------

--- Force a completion trigger now, running `source_order` from the top.
---@param force? boolean
M.complete = function(force)
  if not get_config().enabled then return end
  if force == nil then force = true end
  stop_completion()
  _state.force = force
  trigger_auto()
end

--- Stop the pending autotrigger.
M.stop = function()
  stop_completion()
end

--- Accept the highlighted completion entry, selecting the first (or last, if
--- `direction` is -1) one if none is highlighted yet. If no completion menu is
--- open, jumps to the next (or previous) snippet placeholder when one is
--- active, otherwise sends `fallback_keys` -- so the same key can be mapped for
--- VSCode-style Tab/S-Tab-to-accept behavior without breaking native snippet
--- navigation.
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

--- Confirm the current completion candidate with `<CR>`. With the popup menu
--- open and an entry selected, sends `<C-y>` to accept it -- letting the source
--- expand a snippet or apply additionalTextEdits on CompleteDone. With the menu
--- open but nothing selected, dismisses it and inserts a newline; with no menu,
--- sends a plain `<CR>`. Wired to `<CR>` by the `cr_confirm` config.
M.accept = function()
  if pumvisible() then
    if vim.fn.complete_info({ "selected" }).selected ~= -1 then
      return vim.api.nvim_feedkeys(_accept_keys.yes, "n", false)
    end
    return vim.api.nvim_feedkeys(_accept_keys.cancel, "n", false)
  end
  vim.api.nvim_feedkeys(_accept_keys.cr, "n", false)
end

---@param opts keystone.completion.Config?
M.setup = function(opts)
  M.config = vim.tbl_deep_extend("force", default_config(), opts or {})
  if M.config.enabled then
    apply_config(M.config)
    setup_autocmds()
  end
end

-- Exposed for tests.
M._is_snippet_item = is_snippet_item

return M
