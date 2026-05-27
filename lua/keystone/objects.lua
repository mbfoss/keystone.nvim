local M = {}

-- Maps group key → textobject capture prefix (e.g. "function" → @function.outer / @function.inner)
local CAPTURE_PREFIXES = {
  f = "function",
  c = "class",
  a = "parameter",
  b = "block",
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

-- Returns cursor position as 0-indexed (row, col)
local function cursor_pos()
  local pos = vim.api.nvim_win_get_cursor(0)
  return pos[1] - 1, pos[2]
end

-- True if the 0-indexed range [sr,sc)..(er,ec) contains (row, col)
local function range_contains(sr, sc, er, ec, row, col)
  if row < sr or row > er then return false end
  if row == sr and col < sc then return false end
  if row == er and col >= ec then return false end
  return true
end

-- Returns the smallest captured range that contains the cursor, or nil (all nils on miss)
---@return integer|nil sr
---@return integer|nil sc
---@return integer|nil er
---@return integer|nil ec
local function find_capture(bufnr, lang, capture_name, crow, ccol)
  local ok, query = pcall(vim.treesitter.query.get, lang, "textobjects")
  if not ok or not query then return nil, nil, nil, nil end

  local parser = vim.treesitter.get_parser(bufnr, lang)
  if not parser then return nil, nil, nil, nil end
  local tree = parser:parse()[1]
  if not tree then return nil, nil, nil, nil end

  local best_sr, best_sc, best_er, best_ec
  local best_size = math.huge

  for id, node in query:iter_captures(tree:root(), bufnr, 0, -1) do
    if query.captures[id] == capture_name then
      local sr, sc, er, ec = node:range()
      if range_contains(sr, sc, er, ec, crow, ccol) then
        local size = (er - sr) * 1000000 + (ec - sc)
        if size < best_size then
          best_size = size
          best_sr, best_sc, best_er, best_ec = sr, sc, er, ec
        end
      end
    end
  end

  return best_sr, best_sc, best_er, best_ec
end

-- ec from treesitter is an exclusive 0-indexed col; setpos '> wants the last inclusive 1-indexed col,
-- which is ec (since exclusive-0 == inclusive-1 when nonzero, i.e. ec-1+1 = ec).
local function apply_visual(sr, sc, er, ec)
  vim.fn.setpos("'<", { 0, sr + 1, sc + 1, 0 })
  vim.fn.setpos("'>", { 0, er + 1, ec, 0 })
  vim.cmd("normal! gv")
end

---@param group string
---@param inner boolean
function M.select(group, inner)
  local prefix = CAPTURE_PREFIXES[group]
  if not prefix then return end

  local bufnr = vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local crow, ccol = cursor_pos()

  local suffix = inner and "inner" or "outer"
  local sr, sc, er, ec = find_capture(bufnr, lang, prefix .. "." .. suffix, crow, ccol)

  -- some languages omit .inner captures; fall back to .outer
  if not sr and inner then
    sr, sc, er, ec = find_capture(bufnr, lang, prefix .. ".outer", crow, ccol)
  end

  if not sr then return end
  apply_visual(sr, sc, er, ec)
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
