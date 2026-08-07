local bufdelete = require("keystone.bufdelete")

--- A listed buffer with a real (non-existent-on-disk is fine) name.
---@param name string
---@return integer
local function make_buf(name)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, name)
  return bufnr
end

--- Reset to a single window on a single scratch-ish buffer.
local function reset()
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.cmd("enew")
  local keep = vim.api.nvim_get_current_buf()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if bufnr ~= keep and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end
end

describe("keystone.bufdelete", function()
  before_each(function()
    bufdelete.setup({})
    reset()
  end)

  after_each(reset)

  it("deletes a buffer without closing the windows showing it", function()
    local a = make_buf("/tmp/keystone-a.txt")
    local b = make_buf("/tmp/keystone-b.txt")

    vim.api.nvim_win_set_buf(0, a)
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, a)
    assert.equal(2, #vim.api.nvim_tabpage_list_wins(0))

    assert.is_true(bufdelete.delete(a))

    assert.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.is_false(vim.fn.buflisted(a) == 1)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      assert.not_equal(a, vim.api.nvim_win_get_buf(win))
    end
    assert.is_true(vim.api.nvim_buf_is_valid(b))
  end)

  it("prefers the window's alternate buffer as the replacement", function()
    local a = make_buf("/tmp/keystone-a.txt")
    local b = make_buf("/tmp/keystone-b.txt")

    -- Visiting b then a makes b this window's alternate file.
    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_set_current_buf(a)

    bufdelete.delete(a)
    assert.equal(b, vim.api.nvim_get_current_buf())
  end)

  it("refuses a modified buffer unless forced", function()
    local a = make_buf("/tmp/keystone-a.txt")
    vim.api.nvim_set_current_buf(a)
    vim.api.nvim_buf_set_lines(a, 0, -1, false, { "dirty" })

    assert.is_false(bufdelete.delete(a))
    assert.is_true(vim.api.nvim_buf_is_valid(a))

    assert.is_true(bufdelete.delete(a, { force = true }))
    assert.is_false(vim.fn.buflisted(a) == 1)
  end)

  it("wipes the buffer when asked, rather than only unlisting it", function()
    local a = make_buf("/tmp/keystone-a.txt")
    local b = make_buf("/tmp/keystone-b.txt")
    vim.api.nvim_set_current_buf(b)

    bufdelete.delete(a, { wipe = false })
    assert.is_true(vim.api.nvim_buf_is_valid(a))

    local c = make_buf("/tmp/keystone-c.txt")
    bufdelete.delete(c, { wipe = true })
    assert.is_false(vim.api.nvim_buf_is_valid(c))
  end)

  it("refuses a modified buffer on the wipe path too", function()
    local a = make_buf("/tmp/keystone-a.txt")
    vim.api.nvim_set_current_buf(a)
    vim.api.nvim_buf_set_lines(a, 0, -1, false, { "dirty" })

    assert.is_false(bufdelete.delete(a, { wipe = true }))
    assert.is_true(vim.api.nvim_buf_is_valid(a))
    assert.is_true(vim.bo[a].modified)
  end)

  it("keeps modified buffers out of a bulk delete, on both paths", function()
    local clean = make_buf("/tmp/keystone-clean.txt")
    local dirty = make_buf("/tmp/keystone-dirty.txt")
    vim.api.nvim_buf_set_lines(dirty, 0, -1, false, { "dirty" })
    vim.api.nvim_set_current_buf(clean)

    bufdelete.delete_all({ wipe = true })
    assert.is_true(vim.api.nvim_buf_is_valid(dirty))
    assert.is_true(vim.bo[dirty].modified)

    bufdelete.delete_all()
    assert.is_true(vim.api.nvim_buf_is_valid(dirty))
    assert.is_true(vim.bo[dirty].modified)

    -- ...and it is still on screen, not orphaned by the layout swap.
    assert.is_true(vim.fn.buflisted(dirty) == 1)
  end)

  it("deletes every other listed buffer", function()
    local a = make_buf("/tmp/keystone-a.txt")
    make_buf("/tmp/keystone-b.txt")
    make_buf("/tmp/keystone-c.txt")
    vim.api.nvim_set_current_buf(a)

    bufdelete.delete_others()

    assert.equal(a, vim.api.nvim_get_current_buf())
    for _, bufnr in ipairs(bufdelete.listed()) do
      assert.equal(a, bufnr)
    end
  end)

  it("deletes only buffers no window shows", function()
    local a = make_buf("/tmp/keystone-a.txt")
    local b = make_buf("/tmp/keystone-b.txt")
    vim.api.nvim_set_current_buf(a)

    assert.is_true(vim.tbl_contains(bufdelete.hidden(), b))
    assert.is_false(vim.tbl_contains(bufdelete.hidden(), a))
    bufdelete.delete_hidden()

    assert.equal(a, vim.api.nvim_get_current_buf())
    assert.is_false(vim.fn.buflisted(b) == 1)
    assert.same({ a }, bufdelete.listed())
  end)

  it("leaves the layout on an empty buffer when everything is deleted", function()
    local a = make_buf("/tmp/keystone-a.txt")
    local b = make_buf("/tmp/keystone-b.txt")
    vim.api.nvim_win_set_buf(0, a)
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, b)

    bufdelete.delete_all()

    local wins = vim.api.nvim_tabpage_list_wins(0)
    assert.equal(2, #wins)
    -- One shared empty buffer, not one per window.
    assert.equal(vim.api.nvim_win_get_buf(wins[1]), vim.api.nvim_win_get_buf(wins[2]))
    assert.equal("", vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(wins[1])))
  end)

  it("takes a buffer name as the command argument", function()
    local a = make_buf("/tmp/keystone-a.txt")
    local b = make_buf("/tmp/keystone-b.txt")
    vim.api.nvim_set_current_buf(b)

    vim.cmd("Bdelete /tmp/keystone-a.txt")

    assert.is_false(vim.fn.buflisted(a) == 1)
    assert.equal(b, vim.api.nvim_get_current_buf())
  end)

  it("deletes the buffer given as a count", function()
    local a = make_buf("/tmp/keystone-a.txt")
    local b = make_buf("/tmp/keystone-b.txt")
    vim.api.nvim_set_current_buf(b)

    vim.cmd(a .. "Bdelete")

    assert.is_false(vim.fn.buflisted(a) == 1)
    assert.is_true(vim.fn.buflisted(b) == 1)
  end)

  describe("ignore rules", function()
    it("keeps buffers of an ignored filetype out of a bulk delete", function()
      bufdelete.setup({ ignore_file_types = { "gitcommit" } })
      local keep = make_buf("/tmp/keystone-keep.txt")
      local gone = make_buf("/tmp/keystone-gone.txt")
      vim.bo[keep].filetype = "gitcommit"
      vim.api.nvim_set_current_buf(gone)

      bufdelete.delete_all()

      assert.is_true(vim.fn.buflisted(keep) == 1)
      assert.is_false(vim.fn.buflisted(gone) == 1)
    end)

    it("keeps buffers whose name matches an ignore pattern", function()
      bufdelete.setup({ ignore_filename_patterns = { "%.env$" } })
      local keep = make_buf("/tmp/keystone.env")
      local gone = make_buf("/tmp/keystone-gone.txt")
      vim.api.nvim_set_current_buf(gone)

      bufdelete.delete_all()

      assert.is_true(vim.fn.buflisted(keep) == 1)
      assert.is_false(vim.fn.buflisted(gone) == 1)
    end)

    it("keeps special buffers by default", function()
      local special = make_buf("/tmp/keystone-special.txt")
      vim.bo[special].buftype = "nofile"
      local gone = make_buf("/tmp/keystone-gone.txt")
      vim.api.nvim_set_current_buf(gone)

      bufdelete.delete_all()
      assert.is_true(vim.fn.buflisted(special) == 1)

      bufdelete.setup({ ignore_special_buffers = false })
      bufdelete.delete_all()
      assert.is_false(vim.fn.buflisted(special) == 1)
    end)

    it("keeps the alternate file when asked", function()
      bufdelete.setup({ ignore_alt_file = true })
      local alt = make_buf("/tmp/keystone-alt.txt")
      local cur = make_buf("/tmp/keystone-cur.txt")
      vim.api.nvim_set_current_buf(alt)
      vim.api.nvim_set_current_buf(cur)
      assert.equal(alt, vim.fn.bufnr("#"))

      bufdelete.delete_others()
      assert.is_true(vim.fn.buflisted(alt) == 1)
    end)

    it("keeps buffers shown in a floating window by default", function()
      local floated = make_buf("/tmp/keystone-float.txt")
      vim.api.nvim_open_win(floated, false, {
        relative = "editor", row = 1, col = 1, width = 10, height = 3,
      })
      local gone = make_buf("/tmp/keystone-gone.txt")
      vim.api.nvim_set_current_buf(gone)

      bufdelete.delete_all()

      assert.is_true(vim.fn.buflisted(floated) == 1)
      assert.is_false(vim.fn.buflisted(gone) == 1)
    end)

    it("does not apply to an explicitly named buffer", function()
      bufdelete.setup({ ignore_file_types = { "gitcommit" } })
      local a = make_buf("/tmp/keystone-a.txt")
      vim.bo[a].filetype = "gitcommit"
      vim.api.nvim_set_current_buf(a)

      -- Explicit: goes.
      assert.is_true(bufdelete.delete(a))

      -- ...unless the caller opts into the rules.
      local b = make_buf("/tmp/keystone-b.txt")
      vim.bo[b].filetype = "gitcommit"
      assert.is_false(bufdelete.delete(b, { ignore = true }))
      assert.is_true(vim.fn.buflisted(b) == 1)
    end)

    it("can be turned off for a bulk call", function()
      bufdelete.setup({ ignore_file_types = { "gitcommit" } })
      local a = make_buf("/tmp/keystone-a.txt")
      vim.bo[a].filetype = "gitcommit"
      local b = make_buf("/tmp/keystone-b.txt")
      vim.api.nvim_set_current_buf(b)

      bufdelete.delete_all({ ignore = false })
      assert.is_false(vim.fn.buflisted(a) == 1)
    end)
  end)

  it("registers the four commands", function()
    assert.is_true(vim.fn.exists(":Bdelete") == 2)
    assert.is_true(vim.fn.exists(":Bwipeout") == 2)
    assert.is_true(vim.fn.exists(":Bdeletehidden") == 2)
    assert.is_true(vim.fn.exists(":Bwipeouthidden") == 2)
  end)

  describe("globs", function()
    it("deletes every buffer matching a glob", function()
      local log_a = make_buf("/tmp/keystone-a.log")
      local log_b = make_buf("/tmp/keystone-b.log")
      local txt = make_buf("/tmp/keystone-c.txt")
      vim.api.nvim_set_current_buf(txt)

      vim.cmd("Bdelete *.log")

      assert.is_false(vim.fn.buflisted(log_a) == 1)
      assert.is_false(vim.fn.buflisted(log_b) == 1)
      assert.is_true(vim.fn.buflisted(txt) == 1)
    end)

    it("treats * as every buffer", function()
      local a = make_buf("/tmp/keystone-a.txt")
      local b = make_buf("/tmp/keystone-b.txt")
      vim.api.nvim_set_current_buf(a)

      vim.cmd("Bdelete *")

      assert.is_false(vim.fn.buflisted(a) == 1)
      assert.is_false(vim.fn.buflisted(b) == 1)
    end)

    it("matches the relative path as well as the tail", function()
      local nested = make_buf(vim.fn.getcwd() .. "/lua/keystone/nested.txt")
      local other = make_buf("/tmp/keystone-other.txt")
      vim.api.nvim_set_current_buf(other)

      vim.cmd("Bdelete lua/keystone/*.txt")

      assert.is_false(vim.fn.buflisted(nested) == 1)
      assert.is_true(vim.fn.buflisted(other) == 1)
    end)

    it("warns rather than acting when a glob matches nothing", function()
      local a = make_buf("/tmp/keystone-a.txt")
      vim.api.nvim_set_current_buf(a)

      vim.cmd("Bdelete *.nomatch")

      assert.is_true(vim.fn.buflisted(a) == 1)
    end)

    it("applies the ignore rules to a glob but not to a plain name", function()
      bufdelete.setup({ ignore_filename_patterns = { "%.env$" } })
      local env = make_buf("/tmp/keystone.env")
      vim.api.nvim_set_current_buf(make_buf("/tmp/keystone-other.txt"))

      vim.cmd("Bdelete *")
      assert.is_true(vim.fn.buflisted(env) == 1)

      vim.cmd("Bdelete /tmp/keystone.env")
      assert.is_false(vim.fn.buflisted(env) == 1)
    end)
  end)

  it("has no keyword arguments to shadow a buffer name", function()
    -- The bug this replaced: `all` was a selection, so a buffer called `all`
    -- could not be named.
    local named_all = vim.fn.bufadd(vim.fn.getcwd() .. "/all")
    vim.bo[named_all].buflisted = true
    local other = make_buf("/tmp/keystone-other.txt")
    vim.api.nvim_set_current_buf(other)

    vim.cmd("Bdelete all")

    assert.is_false(vim.fn.buflisted(named_all) == 1)
    assert.is_true(vim.fn.buflisted(other) == 1)
  end)

  describe(":Bdeletehidden / :Bwipeouthidden", function()
    it("deletes every buffer no window is showing", function()
      local keep = make_buf("/tmp/keystone-keep.txt")
      local gone = make_buf("/tmp/keystone-gone.txt")
      vim.api.nvim_set_current_buf(keep)

      vim.cmd("Bdeletehidden")

      assert.is_true(vim.fn.buflisted(keep) == 1)
      assert.is_false(vim.fn.buflisted(gone) == 1)
    end)

    it("keeps a buffer visible in a split of the current tabpage", function()
      local keep = make_buf("/tmp/keystone-keep.txt")
      local split = make_buf("/tmp/keystone-split.txt")
      local gone = make_buf("/tmp/keystone-gone.txt")
      vim.api.nvim_set_current_buf(keep)
      vim.cmd("vsplit")
      vim.api.nvim_set_current_buf(split)

      vim.cmd("Bdeletehidden")

      assert.is_true(vim.fn.buflisted(keep) == 1)
      assert.is_true(vim.fn.buflisted(split) == 1)
      assert.is_false(vim.fn.buflisted(gone) == 1)
    end)

    it("keeps a buffer visible in another tabpage", function()
      local other_tab = make_buf("/tmp/keystone-other-tab.txt")
      local gone = make_buf("/tmp/keystone-gone.txt")

      vim.cmd("tabnew")
      vim.api.nvim_set_current_buf(other_tab)
      vim.cmd("tabprevious")
      local keep = make_buf("/tmp/keystone-keep.txt")
      vim.api.nvim_set_current_buf(keep)

      vim.cmd("Bdeletehidden")

      assert.is_true(vim.fn.buflisted(other_tab) == 1)
      assert.is_true(vim.fn.buflisted(keep) == 1)
      assert.is_false(vim.fn.buflisted(gone) == 1)
    end)

    it("keeps unsaved changes until banged", function()
      local keep = make_buf("/tmp/keystone-keep.txt")
      local dirty = make_buf("/tmp/keystone-dirty.txt")
      vim.api.nvim_buf_set_lines(dirty, 0, -1, false, { "dirty" })
      vim.api.nvim_set_current_buf(keep)

      vim.cmd("Bdeletehidden")
      assert.is_true(vim.fn.buflisted(dirty) == 1)

      vim.cmd("Bdeletehidden!")
      assert.is_false(vim.fn.buflisted(dirty) == 1)
    end)

    it(":Bwipeouthidden wipes where :Bdeletehidden only unlists", function()
      local a = make_buf("/tmp/keystone-a.txt")
      local b = make_buf("/tmp/keystone-b.txt")
      vim.api.nvim_set_current_buf(make_buf("/tmp/keystone-current.txt"))

      vim.cmd("Bdeletehidden")
      assert.is_true(vim.api.nvim_buf_is_valid(a))
      assert.is_true(vim.api.nvim_buf_is_valid(b))

      local c = make_buf("/tmp/keystone-c.txt")
      vim.cmd("Bwipeouthidden")
      assert.is_false(vim.api.nvim_buf_is_valid(c))
    end)

    it("takes no argument", function()
      assert.is_false(pcall(vim.cmd, "Bdeletehidden current"))
      assert.is_false(pcall(vim.cmd, "Bwipeouthidden current"))
    end)
  end)

  it(":Bwipeout wipes where :Bdelete only unlists", function()
    local a = make_buf("/tmp/keystone-a.txt")
    local b = make_buf("/tmp/keystone-b.txt")
    vim.api.nvim_set_current_buf(a)

    vim.cmd("Bdelete")
    assert.is_true(vim.api.nvim_buf_is_valid(a))

    vim.api.nvim_set_current_buf(b)
    vim.cmd("Bwipeout")
    assert.is_false(vim.api.nvim_buf_is_valid(b))
  end)

  it("neither command drops unsaved changes without a bang", function()
    local a = make_buf("/tmp/keystone-a.txt")
    vim.api.nvim_set_current_buf(a)
    vim.api.nvim_buf_set_lines(a, 0, -1, false, { "dirty" })

    vim.cmd("Bdelete")
    assert.is_true(vim.bo[a].modified)
    vim.cmd("Bwipeout")
    assert.is_true(vim.bo[a].modified)
    assert.equal(a, vim.api.nvim_get_current_buf())

    vim.cmd("Bwipeout!")
    assert.is_false(vim.api.nvim_buf_is_valid(a))
  end)
end)
