local M = {}

-- Treesitter textobjects capture pairs for each group
local _TS_CAPS = {
  f = { "function.outer", "function.inner" },
  c = { "class.outer",    "class.inner"    },
  b = { "block.outer",    "block.inner"    },
}

local _KEYMAPS = {
  { { "o", "x" }, "ia", function() M.select("a", true) end,  "inner argument" },
  { { "o", "x" }, "aa", function() M.select("a", false) end, "around argument" },
  { { "o", "x" }, "if", function() M.select("f", true) end,  "inner function" },
  { { "o", "x" }, "af", function() M.select("f", false) end, "around function" },
  { { "o", "x" }, "ic", function() M.select("c", true) end,  "inner class" },
  { { "o", "x" }, "ac", function() M.select("c", false) end, "around class" },
  { { "o", "x" }, "ib", function() M.select("b", true) end,  "inner block" },
  { { "o", "x" }, "ab", function() M.select("b", false) end, "around block" },
}

local function _range_contains(sr, sc, er, ec, row, col)
  if row < sr or row > er then return false end
  if row == sr and col < sc then return false end
  if row == er and col >= ec then return false end
  return true
end

-- Find the smallest textobjects capture containing the cursor.
-- Walks up the language tree for injected languages, same as mini.ai.
local function _ts_find(bufnr, capture_name, crow, ccol)
  local parser = vim.treesitter.get_parser(bufnr, nil, { error = false })
  if not parser then return end

  ---@type vim.treesitter.LanguageTree|nil
  local lt = parser:language_for_range({ crow, ccol, crow, ccol })

  while lt do
    local query = vim.treesitter.query.get(lt:lang(), "textobjects")
    if query then
      local trees = lt:parse()
      if trees and trees[1] then
        local best_sr, best_sc, best_er, best_ec
        local best_size = math.huge
        for id, node in query:iter_captures(trees[1]:root(), bufnr, 0, -1) do
          if query.captures[id] == capture_name then
            local sr, sc, er, ec = node:range()
            if _range_contains(sr, sc, er, ec, crow, ccol) then
              local size = (er - sr) * 1000000 + (ec - sc)
              if size < best_size then
                best_size = size
                best_sr, best_sc, best_er, best_ec = sr, sc, er, ec
              end
            end
          end
        end
        if best_sr then return best_sr, best_sc, best_er, best_ec end
      end
    end
    lt = lt:parent()
  end
end

-- Apply a visual selection from a 0-indexed treesitter range (exclusive end col).
local function _apply_ts_visual(sr, sc, er, ec)
  vim.fn.setpos("'<", { 0, sr + 1, sc + 1, 0 })
  vim.fn.setpos("'>", { 0, er + 1, ec, 0 })
  vim.cmd("normal! gv")
end

-- Bracket-based argument selection, same approach as mini.ai gen_spec.argument().
-- All positions here are 1-indexed (vim.fn convention).
local function _arg_select(inner)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  col = col + 1  -- 0→1 indexed

  local save = vim.fn.getpos(".")

  -- Find the innermost enclosing bracket pair
  local bracket_pairs = { { "(", ")" }, { "\\[", "\\]" }, { "{", "}" } }
  local best

  for _, p in ipairs(bracket_pairs) do
    vim.fn.cursor(row, col)
    local orow, ocol = unpack(vim.fn.searchpairpos(p[1], "", p[2], "bWn"))
    if orow > 0 then
      vim.fn.cursor(orow, ocol)
      local crow, ccol = unpack(vim.fn.searchpairpos(p[1], "", p[2], "Wn"))
      if crow > 0 then
        -- Innermost = latest (deepest) opening bracket position
        if not best or orow > best.or_ or (orow == best.or_ and ocol > best.oc) then
          best = { or_ = orow, oc = ocol, cr = crow, cc = ccol }
        end
      end
    end
  end

  vim.fn.setpos(".", save)
  if not best then return end

  -- Collect top-level comma positions between the bracket edges (1-indexed)
  local bufnr = vim.api.nvim_get_current_buf()
  local seps = { { r = best.or_, c = best.oc } }
  local lines = vim.api.nvim_buf_get_lines(bufnr, best.or_ - 1, best.cr, false)
  local depth = 0

  for li, line in ipairs(lines) do
    local lr = best.or_ - 1 + li
    local cs = (li == 1) and (best.oc + 1) or 1
    local ce = (lr == best.cr) and (best.cc - 1) or #line
    for ci = cs, ce do
      local ch = line:sub(ci, ci)
      if ch == "(" or ch == "[" or ch == "{" then
        depth = depth + 1
      elseif ch == ")" or ch == "]" or ch == "}" then
        depth = depth - 1
      elseif ch == "," and depth == 0 then
        seps[#seps + 1] = { r = lr, c = ci }
      end
    end
  end
  seps[#seps + 1] = { r = best.cr, c = best.cc }

  -- Locate the segment the cursor falls into
  for i = 1, #seps - 1 do
    local s, e = seps[i], seps[i + 1]
    local after = s.r < row or (s.r == row and s.c < col)
    local before = e.r > row or (e.r == row and e.c >= col)
    if after and before then
      local sr, sc, er, ec  -- 1-indexed, inclusive
      if inner then
        sr, sc = s.r, s.c + 1  -- one past separator
        er, ec = e.r, e.c - 1  -- one before next separator
        -- Trim leading whitespace
        local line = vim.api.nvim_buf_get_lines(bufnr, sr - 1, sr, false)[1] or ""
        while sc <= #line and line:sub(sc, sc) == " " do sc = sc + 1 end
        -- Trim trailing whitespace
        line = vim.api.nvim_buf_get_lines(bufnr, er - 1, er, false)[1] or ""
        while ec >= 1 and line:sub(ec, ec) == " " do ec = ec - 1 end
      elseif i > 1 then
        -- Non-first arg: include leading comma
        sr, sc = s.r, s.c
        er, ec = e.r, e.c - 1
      else
        -- First arg: include trailing comma if present, otherwise just content
        sr, sc = s.r, s.c + 1
        er, ec = e.r, (i + 1 < #seps) and e.c or e.c - 1
      end
      if not (sr > er or (sr == er and sc > ec)) then
        vim.fn.setpos("'<", { 0, sr, sc, 0 })
        vim.fn.setpos("'>", { 0, er, ec, 0 })
        vim.cmd("normal! gv")
      end
      return
    end
  end
end

---@param group string
---@param inner boolean
function M.select(group, inner)
  if group == "a" then
    _arg_select(inner)
    return
  end

  local caps = _TS_CAPS[group]
  if not caps then return end

  local bufnr = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local crow, ccol = pos[1] - 1, pos[2]
  local capture = inner and caps[2] or caps[1]

  local sr, sc, er, ec = _ts_find(bufnr, capture, crow, ccol)
  if not sr and inner then
    sr, sc, er, ec = _ts_find(bufnr, caps[1], crow, ccol)
  end
  if not sr then return end

  _apply_ts_visual(sr, sc, er, ec)
end

---@class keystone.textobjects.Config
---@field enabled boolean

---@type keystone.textobjects.Config
M.config = { enabled = true }

function M.enable()
  for _, km in ipairs(_KEYMAPS) do
    vim.keymap.set(km[1], km[2], km[3], { desc = km[4] })
  end
end

function M.disable()
  for _, km in ipairs(_KEYMAPS) do
    for _, mode in ipairs(km[1]) do
      pcall(vim.keymap.del, mode, km[2])
    end
  end
end

---@param opts keystone.textobjects.Config|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  if M.config.enabled then M.enable() end
end

return M
