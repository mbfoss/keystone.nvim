local M = {}

---@alias keystone.objects.Range { [1]:integer, [2]:integer, [3]:integer, [4]:integer }

local KEYMAPS = {
  { { "o", "x" }, "ia", function() M.select_argument(true) end,  "inner argument" },
  { { "o", "x" }, "aa", function() M.select_argument(false) end, "around argument" },
  { { "o", "x" }, "if", function() M.select_function(true) end,  "inner function" },
  { { "o", "x" }, "af", function() M.select_function(false) end, "around function" },
  { { "o", "x" }, "ic", function() M.select_class(true) end,     "inner class" },
  { { "o", "x" }, "ac", function() M.select_class(false) end,    "around class" },
  { { "o", "x" }, "ib", function() M.select_block(true) end,     "inner block" },
  { { "o", "x" }, "ab", function() M.select_block(false) end,    "around block" },
}

---@param bufnr integer
---@return vim.treesitter.LanguageTree|nil
local function get_parser(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok then return nil end
  return parser
end

---@return TSNode|nil
local function get_node_at_cursor()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]

  local parser = get_parser(0)
  if not parser then return nil end

  local tree = parser:parse()[1]
  if not tree then return nil end

  return tree:root():named_descendant_for_range(row, col, row, col)
end

---@param node TSNode|nil
---@param types string[]
---@return TSNode|nil
local function find_parent(node, types)
  while node do
    for _, t in ipairs(types) do
      if node:type() == t then
        return node
      end
    end
    node = node:parent()
  end
  return nil
end

---@param node TSNode
---@return keystone.objects.Range
local function node_range(node)
  local sr, sc, er, ec = node:range()
  return { sr, sc, er, ec }
end

---@param range keystone.objects.Range
local function set_visual(range)
  vim.fn.setpos("'<", { 0, range[1] + 1, range[2] + 1, 0 })
  vim.fn.setpos("'>", { 0, range[3] + 1, range[4], 0 })
  vim.cmd("normal! gv")
end

local BODY_TYPES = { body = true, block = true, statement_block = true, field_declaration_list = true }

---@param node TSNode|nil
---@param inner boolean
local function select_node(node, inner)
  if not node then return end
  if not inner then
    set_visual(node_range(node))
    return
  end
  -- For inner: prefer a dedicated body/block child (more accurate for functions/classes)
  for child in node:iter_children() do
    if BODY_TYPES[child:type()] then
      set_visual(node_range(child))
      return
    end
  end
  -- Fallback: span from first to last named child
  local first, last
  for child in node:iter_children() do
    if child:named() then
      first = first or child
      last = child
    end
  end
  if not first or not last then
    set_visual(node_range(node))
    return
  end
  local sr, sc = first:range()
  local _, _, er, ec = last:range()
  set_visual({ sr, sc, er, ec })
end

---@param types string[]
---@return TSNode|nil
local function get_node(types)
  local node = get_node_at_cursor()
  if not node then return nil end
  return find_parent(node, types)
end

function M.select_argument(inner)
  local node = get_node(
    {
      "parameters",
      "parameter_list",
      "arguments",
      "argument_list",
      "identifier",
    }
  )
  if node then
    select_node(node, inner)
  end
end

function M.select_function(inner)
  local node = get_node({
    "function_definition",
    "function_declaration",
    "method_definition",
    "method_declaration",
    "arrow_function",
    "func_literal",
    "function",
  })
  if node then
    select_node(node, inner)
  end
end

function M.select_class(inner)
  local node = get_node(
    {
      "class_definition",
      "class_declaration",
      "class_specifier",
      "struct_specifier"
    }
  )
  if node then
    select_node(node, inner)
  end
end

function M.select_block(inner)
  local node = get_node(
    {
      "block",
      "statement_block",
    }
  )
  if node then
    select_node(node, inner)
  end
end

---@class keystone.textobjects.Config
---@field enabled boolean

---@type keystone.textobjects.Config
M.config = {
  enabled = true,
}

function M.enable()
  for _, km in ipairs(KEYMAPS) do
    vim.keymap.set(km[1], km[2], km[3], { desc = km[4] })
  end
end

function M.disable()
  for _, km in ipairs(KEYMAPS) do
    for _, mode in ipairs(km[1]) do
      pcall(vim.keymap.del, mode, km[2])
    end
  end
end

---@param opts keystone.textobjects.Config|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  if M.config.enabled then
    M.enable()
  end
end

return M
