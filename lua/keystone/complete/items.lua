--- Pure LSP completion-item processing: turning `textDocument/completion`
--- results into `complete()`-shaped candidate lists. Nothing here touches
--- editor state, so it is unit-testable in isolation.
local M = {}

---@param item table
---@return string
function M.filter_word(item) return item.filterText or item.label end

---@param item table
---@return string
function M.word(item)
  return vim.tbl_get(item, "textEdit", "newText") or item.insertText or M.filter_word(item) or ""
end

--- Whether `word` actually contains snippet syntax (tab stops / placeholders /
--- newlines). A server may flag an item as a snippet while its body is a plain
--- string, in which case it should be inserted verbatim.
---@param word string
---@return boolean
function M.is_snippet_body(word)
  return (word:find("[^\\]%${?%w") or word:find("^%${?%w") or word:find("[\n\t]")) ~= nil
end

--- Fold a completion list's `itemDefaults` into each item in place.
---@param items table
---@param defaults table
---@return table
function M.apply_defaults(items, defaults)
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

--- Convert LSP completion items into `complete()` candidate entries.
---@param items table
---@return table
function M.to_vim(items)
  if #items == 0 then return {} end

  local res        = {}
  local item_kinds = vim.lsp.protocol.CompletionItemKind
  local snip_kind  = vim.lsp.protocol.CompletionItemKind.Snippet
  local snip_fmt   = vim.lsp.protocol.InsertTextFormat.Snippet

  for i, item in ipairs(items) do
    local word       = M.word(item)
    local is_sk      = item.kind == snip_kind
    local is_sf      = item.insertTextFormat == snip_fmt
    local is_snippet = (is_sk or is_sf) and M.is_snippet_body(word)

    local details    = item.labelDetails or {}
    local menu_parts = {}
    if is_snippet then menu_parts[#menu_parts + 1] = "S" end
    if details.detail and details.detail ~= "" then menu_parts[#menu_parts + 1] = details.detail end
    if details.description and details.description ~= "" then menu_parts[#menu_parts + 1] = details.description end
    local menu = table.concat(menu_parts, " ")

    res[#res + 1] = {
      word = is_snippet and M.filter_word(item) or word,
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
    }
  end
  return res
end

---@type table<integer, string>?
local _kind_map -- integer CompletionItemKind -> name, lazily built

local function build_kind_map()
  if _kind_map then return end
  _kind_map = {}
  for k, v in pairs(vim.lsp.protocol.CompletionItemKind) do
    if type(k) == "string" and type(v) == "number" then _kind_map[v] = k end
  end
end

--- Stable-sort items by kind priority (higher first); a negative priority
--- drops the kind entirely.
---@param items table
---@param kind_priority table
---@return table
function M.sort_by_kind(items, kind_priority)
  build_kind_map()
  local map = _kind_map --[[@as table<integer, string>]]
  local raw = {}
  for i, item in ipairs(items) do
    local priority = kind_priority[map[item.kind]] or 100
    if priority >= 0 then raw[#raw + 1] = { priority, i, item } end
  end
  table.sort(raw, function(a, b) return a[1] > b[1] or (a[1] == b[1] and a[2] < b[2]) end)
  return vim.tbl_map(function(x) return x[3] end, raw)
end

--- Tag deprecated items with a highlight group, in place.
---@param items table
---@return table
function M.add_hlgroups(items)
  local deprecated_tag = vim.lsp.protocol.CompletionTag.Deprecated
  for _, item in ipairs(items) do
    local deprecated = item.deprecated
        or (item.tags and vim.list_contains(item.tags, deprecated_tag))
    item.abbr_hlgroup = item.abbr_hlgroup
        or (deprecated and "KeystoneCompletionDeprecated" or nil)
  end
  return items
end

--- Default filter+sort: keep items whose filter word is a prefix of `base`.
---@param items table
---@param base string
---@return table
function M.filter_sort(items, base)
  if base == "" then
    return vim.deepcopy(items)
  end

  local res = {}
  for _, item in ipairs(items) do
    if vim.startswith(M.filter_word(item), base) then
      res[#res + 1] = vim.deepcopy(item)
    end
  end
  return res
end

return M
