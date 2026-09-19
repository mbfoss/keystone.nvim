local scope = require("keystone.scope")

local _SAMPLE = {
  "local M = {}",          -- 1
  "",                      -- 2
  "function M.foo(a)",     -- 3
  "  if a then",           -- 4
  "    local x = 1",       -- 5
  "",                      -- 6
  "    return x",          -- 7
  "  end",                 -- 8
  "  return 0",            -- 9
  "end",                   -- 10
  "",                      -- 11
  "return M",              -- 12
}

--- Open `lines` in a real file buffer, since scratch buffers are skipped.
---@param lines string[]
---@param ext string
local function open_file(lines, ext)
  local path = vim.fn.tempname() .. ext
  vim.fn.writefile(lines, path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.bo.shiftwidth = 2
end

---@param lnum integer
local function cursor(lnum)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
end

--- Screen cells of the first `rows` rows holding `char`, as "row:col". A plain
--- `:redraw` only draws what the module asked to be redrawn.
---@param char string
---@param rows integer
---@return table<string, true>
local function cells(char, rows)
  vim.cmd("redraw")
  local out = {}
  for r = 1, rows do
    for c = 1, 30 do
      if vim.fn.screenstring(r, c) == char then out[r .. ":" .. c] = true end
    end
  end
  return out
end

describe("scope setup", function()
  after_each(function() scope.disable() end)

  it("enables by default and honours enabled = false", function()
    scope.setup()
    assert.is_true(scope.is_enabled())
    scope.setup({ enabled = false })
    assert.is_false(scope.is_enabled())
  end)

  it("toggles", function()
    scope.setup()
    scope.toggle()
    assert.is_false(scope.is_enabled())
    scope.toggle()
    assert.is_true(scope.is_enabled())
  end)
end)

describe("scope without treesitter", function()
  before_each(function()
    scope.setup()
    open_file(_SAMPLE, ".txt")
    vim.bo.filetype = "conf"
  end)
  after_each(function() scope.disable() end)

  it("is nil", function()
    cursor(5)
    assert.is_nil(scope.get())
  end)
end)

describe("scope by treesitter", function()
  before_each(function()
    scope.setup()
    open_file(_SAMPLE, ".lua")
    vim.treesitter.start(0, "lua")
    vim.treesitter.get_parser(0):parse()
  end)
  after_each(function() scope.disable() end)

  it("is the body of the enclosing node", function()
    cursor(9)
    assert.same({ col = 0, first = 4, last = 9 }, scope.get())
    cursor(5)
    assert.same({ col = 2, first = 5, last = 7 }, scope.get())
  end)

  it("selects the node's body from its header and closing lines", function()
    cursor(4)
    assert.same({ col = 2, first = 5, last = 7 }, scope.get())
    cursor(8)
    assert.same({ col = 2, first = 5, last = 7 }, scope.get())
  end)

  it("is nil at the top level", function()
    cursor(12)
    assert.is_nil(scope.get())
  end)

  it("skips excluded filetypes", function()
    vim.bo.filetype = "markdown"
    cursor(5)
    assert.is_nil(scope.get())
  end)
end)

describe("scope by treesitter as it reparses", function()
  local lines = { "local function f()", "  local x = 1", "  return x", "end" }

  before_each(function()
    scope.setup()
    open_file(lines, ".lua")
    -- As a FileType handler would: the first parse lands during the redraw.
    vim.treesitter.start(0, "lua")
    cursor(2)
    vim.api.nvim_exec_autocmds("CursorMoved", {})
  end)
  after_each(function() scope.disable() end)

  it("is drawn once the first parse lands", function()
    assert.same({ ["2:1"] = true, ["3:1"] = true }, cells(scope.config.scope_char, #lines))
  end)

  it("follows an edit that changes the tree", function()
    cells(scope.config.scope_char, #lines)
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "  if x then", "    y()", "  end" })
    cursor(3)
    vim.api.nvim_exec_autocmds("TextChanged", {})
    assert.same({ ["3:3"] = true }, cells(scope.config.scope_char, #lines + 2))
  end)
end)

describe("scope rendering", function()
  local lines = {
    "function M.foo(a)",
    "  if a then",
    "",
    "    local x = foo(1,",
    "                  2)",
    "",
    "  end",
    "end",
  }

  after_each(function() scope.disable() end)

  it("draws the scope only where an indent guide would be", function()
    open_file(lines, ".lua")
    vim.treesitter.start(0, "lua")
    vim.treesitter.get_parser(0):parse()
    -- Indented by 2 with 'shiftwidth' 4: guides follow the text, not sw.
    vim.bo.shiftwidth = 4

    scope.setup({ scope = false, guides = true })
    local guides = cells(scope.config.guide_char, #lines)
    assert.is_true(guides["2:1"])
    assert.is_true(guides["3:3"])

    scope.setup({ scope = true, guides = false })
    for lnum = 1, #lines do
      cursor(lnum)
      vim.api.nvim_exec_autocmds("CursorMoved", {})
      for cell in pairs(cells(scope.config.scope_char, #lines)) do
        assert(guides[cell], ("cursor %d: scope at %s without a guide"):format(lnum, cell))
      end
    end
  end)

  it("follows edits that change indents or shift lines", function()
    local body = { "t = {" }
    for _ = 1, 38 do body[#body + 1] = "  x," end
    body[#body + 1] = "}"
    open_file(body, ".lua")
    scope.setup({ scope = false, guides = true })
    assert.is_true(cells(scope.config.guide_char, 10)["6:1"])

    vim.api.nvim_buf_set_lines(0, 5, 6, false, { "x," })
    local guides = cells(scope.config.guide_char, 10)
    assert.is_nil(guides["6:1"])
    assert.is_true(guides["7:1"])

    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "a = 1", "b = 2" })
    guides = cells(scope.config.guide_char, 10)
    assert.is_nil(guides["8:1"])
    assert.is_true(guides["6:1"])
  end)

  it("keeps guides past a line shallower than its block", function()
    open_file({
      "function M.foo(a)",
      "  if a then",
      "    x()",
      "#ifdef FOO",
      "    y()",
      "  end",
      "end",
      "function M.bar()",
      "  z()",
      "end",
    }, ".txt")
    vim.bo.filetype = "conf"
    scope.setup({ scope = false, guides = true })
    local guides = cells(scope.config.guide_char, 10)
    assert.is_true(guides["5:1"])
    assert.is_true(guides["5:3"])
    assert.is_nil(guides["9:3"])
    -- Same result when drawing starts below the shallow line.
    vim.cmd("5")
    vim.cmd("normal! zt")
    guides = cells(scope.config.guide_char, 1)
    assert.is_true(guides["1:1"])
    assert.is_true(guides["1:3"])
  end)

  it("keeps a guide for a body after a wrapped header", function()
    open_file({
      "void f(",
      "    int value) {",
      "  int a = 1;",
      "  int b = 2;",
      "  {",
      "    int c = 3;",
      "  }",
      "}",
    }, ".txt")
    vim.bo.filetype = "conf"
    scope.setup({ scope = false, guides = true })
    local guides = cells(scope.config.guide_char, 8)
    assert.is_true(guides["6:1"])
    assert.is_true(guides["6:3"])
  end)

  it("keeps guides past closed folds, small or large", function()
    for _, size in ipairs({ 3, 1100 }) do
      local src = { "class A:", "  def f():" }
      for _ = 1, size do src[#src + 1] = "    a()" end
      vim.list_extend(src, { "  def g():", "    b()", "  c()" })
      open_file(src, ".txt")
      vim.bo.filetype = "conf"
      vim.wo.foldmethod = "manual"
      vim.wo.foldenable = true
      vim.wo.foldlevel = 0
      scope.setup({ scope = false, guides = true })
      vim.cmd(("2,%dfold"):format(size + 2))
      vim.cmd("1")
      -- Screen rows: 1 class, 2 fold, 3 def g, 4 b(), 5 c().
      local guides = cells(scope.config.guide_char, 5)
      assert.same({ ["3:1"] = true, ["4:1"] = true, ["4:3"] = true, ["5:1"] = true }, guides,
        ("fold of %d lines"):format(size + 1))
      vim.cmd("bwipeout!")
    end
  end)

  it("keeps guides past comments left of their block, wherever drawing starts", function()
    local src = {
      "int main() {",
      "  {",
      "    int a = 1;",
      "// one",
      "    int b = 2;",
      "// two",
      "// lines",
      "    int c = 3;",
      "  }",
      "}",
    }
    open_file(src, ".c")
    vim.bo.commentstring = "// %s"
    vim.treesitter.start(0, "c")
    vim.treesitter.get_parser(0):parse()
    scope.setup({ scope = false, guides = true })
    for top = 1, 8 do
      vim.cmd(tostring(top))
      vim.cmd("normal! zt")
      local guides = cells(scope.config.guide_char, #src - top + 1)
      for _, lnum in ipairs({ 5, 8 }) do
        if lnum >= top then
          local row = lnum - top + 1
          assert(guides[row .. ":1"] and guides[row .. ":3"],
            ("top %d: missing guide on line %d"):format(top, lnum))
        end
      end
    end

    scope.setup({ scope = true, guides = false })
    cursor(3)
    assert.same({ col = 2, first = 3, last = 8 }, scope.get())
  end)
end)
