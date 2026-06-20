local tweaks = require("keystone.tweaks")

local function augroup_exists(name)
  -- nvim_get_autocmds errors when the group does not exist.
  local ok = pcall(vim.api.nvim_get_autocmds, { group = name })
  return ok
end

describe("tweaks setup", function()
  after_each(function()
    tweaks.disable()
  end)

  it("activates exactly the features enabled in the default config", function()
    tweaks.setup()
    for _, name in ipairs(tweaks.feature_names()) do
      assert.equal(tweaks.config[name] == true, tweaks.is_active(name))
    end
  end)

  it("respects per-feature flags", function()
    tweaks.setup({ highlight_on_yank = false, trim_whitespace = true })
    assert.is_false(tweaks.is_active("highlight_on_yank"))
    assert.is_true(tweaks.is_active("trim_whitespace"))
    assert.is_true(tweaks.is_active("restore_cursor"))
  end)

  it("tears everything down when enabled = false", function()
    tweaks.setup({ enabled = false })
    for _, name in ipairs(tweaks.feature_names()) do
      assert.is_false(tweaks.is_active(name))
    end
  end)

  it("is idempotent across repeated setup calls", function()
    tweaks.setup()
    tweaks.setup()
    assert.is_true(tweaks.is_active("restore_cursor"))
  end)
end)

describe("tweaks feature toggling", function()
  before_each(function()
    tweaks.setup()
  end)
  after_each(function()
    tweaks.disable()
  end)

  it("installs and removes the augroup with the feature", function()
    assert.is_true(augroup_exists("keystone_tweaks_yank"))
    tweaks.disable_feature("highlight_on_yank")
    assert.is_false(tweaks.is_active("highlight_on_yank"))
    assert.is_false(augroup_exists("keystone_tweaks_yank"))

    tweaks.enable_feature("highlight_on_yank")
    assert.is_true(tweaks.is_active("highlight_on_yank"))
    assert.is_true(augroup_exists("keystone_tweaks_yank"))
  end)

  it("toggle_feature flips active state", function()
    local before = tweaks.is_active("auto_reload")
    tweaks.toggle_feature("auto_reload")
    assert.are_not.equal(before, tweaks.is_active("auto_reload"))
    tweaks.toggle_feature("auto_reload")
    assert.equal(before, tweaks.is_active("auto_reload"))
  end)

  it("ignores unknown features", function()
    assert.has_no.errors(function()
      tweaks.enable_feature("nope")
      tweaks.disable_feature("nope")
    end)
    assert.is_false(tweaks.is_active("nope"))
  end)
end)

describe("tweaks behaviours", function()
  after_each(function()
    tweaks.disable()
  end)

  it("auto_create_dir makes missing parent directories on write", function()
    tweaks.setup()
    local dir = vim.fn.tempname()
    local file = dir .. "/nested/deep/file.txt"
    assert.equals(0, vim.fn.isdirectory(dir))

    vim.cmd.edit(vim.fn.fnameescape(file))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "hello" })
    vim.cmd("silent write")

    assert.equals(1, vim.fn.filereadable(file))
    vim.fn.delete(dir, "rf")
  end)

  it("trim_whitespace strips trailing whitespace on save when enabled", function()
    tweaks.setup({ trim_whitespace = true })
    local file = vim.fn.tempname()
    vim.cmd.edit(vim.fn.fnameescape(file))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "keep   ", "clean" })
    vim.cmd("silent write")

    assert.same({ "keep", "clean" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.fn.delete(file)
  end)
end)
