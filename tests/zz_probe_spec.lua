local scope = require("keystone.scope")

local function open_file(lines, ext)
  local path = vim.fn.tempname() .. ext
  vim.fn.writefile(lines, path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.bo.shiftwidth = 2
end

--- Render visible screen rows as text, substituting the guide/scope chars.
local function screenshot(rows)
  vim.cmd("redraw")
  print("    +" .. string.rep("-", 28) .. "+")
  for r = 1, rows do
    local s = {}
    for c = 1, 28 do
      local ch = vim.fn.screenstring(r, c)
      if ch == "" then ch = " " end
      s[#s + 1] = ch
    end
    print(("  %2d|%s|"):format(r, table.concat(s)))
  end
  print("    +" .. string.rep("-", 28) .. "+")
end

local function run(lines, name, cursor_lnum)
  open_file(lines, ".lua")
  vim.treesitter.start(0, "lua")
  vim.treesitter.get_parser(0):parse()
  scope.setup()
  cursor_lnum = cursor_lnum or math.floor(#lines / 2)
  vim.api.nvim_win_set_cursor(0, { cursor_lnum, 0 })
  vim.cmd("normal! zt")
  print(("=== %s (cursor %d)"):format(name, cursor_lnum))
  screenshot(#lines)
  vim.cmd("bwipeout!")
end

describe("probe blank screenshot", function()
  it("dumps", function()
    run({
      "function a()",
      "  if x then",
      "    p()",
      "",
      "    q()",
      "  end",
      "end",
    }, "nested blank", 5)

    run({
      "function a()",
      "  p()",
      "",
      "",
      "  q()",
      "end",
    }, "two blanks", 3)

    run({
      "if x then",
      "  a()",
      "",
      "end",
      "",
      "b()",
    }, "blank before end + top level", 2)

    run({
      "function outer()",
      "  function inner()",
      "    a()",
      "",
      "  end",
      "  b()",
      "end",
    }, "blank closing inner", 3)
  end)
end)
