local Keys = require("keystone.clue.keys")
local Tree = require("keystone.clue.tree")
local clue = require("keystone.clue")

--- Feed keys and synchronously drain typeahead so the engine's getchar loop
--- runs to completion inside this call.
local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, true, true), "x", false)
end

describe("keystone.clue.keys", function()
  it("splits chords and multibyte into single tokens", function()
    assert.same({ "<C-W>", "s" }, Keys.split(Keys.norm("<C-w>s")))
    assert.same({ "g", "d" }, Keys.split(Keys.norm("gd")))
  end)

  it("maps visual spec mode to the x mapmode", function()
    assert.equal("x", Keys.spec_mode("v"))
    assert.equal("n", Keys.spec_mode("n"))
  end)
end)

describe("keystone.clue.tree", function()
  it("builds groups and children from clues + keymaps", function()
    vim.g.mapleader = " "
    clue.setup({ delay = 0 })
    clue._clues = {}
    clue.add({ { "<leader>f", group = "+Find" } })
    vim.keymap.set("n", "<leader>ff", "<nop>", { desc = "Find files" })
    vim.keymap.set("n", "<leader>fg", "<nop>", { desc = "Live grep" })

    local root = Tree.build("n", clue.get_clues("n"), clue.get_builtins("n"))
    local fnode = Tree.find(root, Keys.norm("<leader>f"))
    assert.is_truthy(fnode)
    assert.is_true(fnode.group)

    local by_desc = {}
    for _, k in ipairs(Tree.children(fnode)) do by_desc[k.desc] = true end
    assert.is_true(by_desc["Find files"])
    assert.is_true(by_desc["Live grep"])

    pcall(vim.keymap.del, "n", "<leader>ff")
    pcall(vim.keymap.del, "n", "<leader>fg")
  end)

  it("ignores its own trigger keymaps", function()
    clue.setup({ delay = 0 })
    local root = Tree.build("n", clue.get_clues("n"), clue.get_builtins("n"))
    -- No node may carry one of our trigger keymaps.
    local function walk(node)
      if node.keymap and node.keymap.desc
        and node.keymap.desc:find("keystone-clue-trigger", 1, true) then
        return true
      end
      for _, child in pairs(node.children) do
        if walk(child) then return true end
      end
      return false
    end
    assert.is_false(walk(root))
  end)
end)

describe("keystone.clue engine", function()
  before_each(function()
    vim.g.mapleader = " "
    clue._clues = {}
    clue.setup({ delay = 0 })
    clue.add({ { "<leader>f", group = "+Find" } })
  end)

  it("re-feeds resolved sequences to run the real mapping", function()
    local hits = 0
    vim.keymap.set("n", "<leader>ff", function() hits = hits + 1 end)
    press("<leader>ff")
    assert.equal(1, hits)
    pcall(vim.keymap.del, "n", "<leader>ff")
  end)

  it("preserves counts on passthrough motions", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "1", "2", "3", "4", "5" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    press("3gj")
    assert.equal(4, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("cancels on <Esc> without running a mapping", function()
    local hits = 0
    vim.keymap.set("n", "<leader>ff", function() hits = hits + 1 end)
    press("<leader>f<Esc>")
    assert.equal(0, hits)
    pcall(vim.keymap.del, "n", "<leader>ff")
  end)

  it("navigates up a level on <BS>", function()
    local hits = 0
    vim.keymap.set("n", "<leader>ff", function() hits = hits + 1 end)
    press("<leader>f<BS>ff")
    assert.equal(1, hits)
    pcall(vim.keymap.del, "n", "<leader>ff")
  end)
end)
