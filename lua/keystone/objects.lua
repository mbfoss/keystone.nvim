local M = {}

-- Substring patterns matched against node:type() to identify semantic groups
local GROUPS = {
  f = { "function", "method", "arrow", "func_literal" },
  c = { "class", "struct", "interface", "impl" },
  a = { "parameter", "argument" },
  b = { "block", "body" },
}

local KEYMAPS = {
  { { "o", "x" }, "ia", function() M.select("a", true) end,  "inner argument" },
  { { "o", "x" }, "aa", function() M.select("a", false) end, "around argument" },
  { { "o", "x" }, "if", function() M.select("f", true) end,  "inner function" },
  { { "o", "x" }, "af", function() M.select("f", false) end, "around function" },
  { { "o", "x" }, "ic", function() M.select("c", true) end,  "inner class" },
  { { "o", "x" }, "ac", function() M.select("c", false) end, "around class" },
  { { "o", "x" }, "ib", function() M.select("b", true) end,  "inner block" },
  { { "o", "x" }, "ab", function() M.select("b", false) end, "around block" },
}

---@param node TSNode
---@param patterns string[]
---@return boolean
local function matches(node, patterns)
  local t = node:type()
  for _, p in ipairs(patterns) do
    if t:find(p, 1, true) then return true end
  end
  return false
end

---@param node TSNode|nil
---@param patterns string[]
---@return TSNode|nil
local function find_ancestor(node, patterns)
  while node do
    if matches(node, patterns) then return node end
    node = node:parent()
  end
end

-- Returns the child of the first ancestor matching patterns (i.e. a single item in a list)
---@param node TSNode|nil
---@param patterns string[]
---@return TSNode|nil
local function find_in_container(node, patterns)
  while node do
    local parent = node:parent()
    if parent and matches(parent, patterns) then return node end
    node = parent
  end
end

local BODY_PATTERNS = { "block", "body", "statement" }

---@param node TSNode|nil
---@param inner boolean
local function apply_visual(node, inner)
  if not node then return end
  local sr, sc, er, ec

  if inner then
    for child in node:iter_children() do
      if matches(child, BODY_PATTERNS) then
        sr, sc, er, ec = child:range()
        break
      end
    end
    if not sr then
      local first, last
      for child in node:iter_children() do
        if child:named() then
          first = first or child
          last = child
        end
      end
      if first then
        sr, sc = first:range()
        _, _, er, ec = last:range()
      end
    end
  end

  if not sr then
    sr, sc, er, ec = node:range()
  end

  vim.fn.setpos("'<", { 0, sr + 1, sc + 1, 0 })
  vim.fn.setpos("'>", { 0, er + 1, ec, 0 })
  vim.cmd("normal! gv")
end

---@param group string
---@param inner boolean
function M.select(group, inner)
  local patterns = GROUPS[group]
  if not patterns then return end
  local node = vim.treesitter.get_node()
  if not node then return end
  local target = group == "a"
    and find_in_container(node, patterns)
    or find_ancestor(node, patterns)
  apply_visual(target, inner)
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
