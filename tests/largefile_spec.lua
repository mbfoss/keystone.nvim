local largefile = require("keystone.largefile")

local function augroup_exists(name)
  -- nvim_get_autocmds errors when the group does not exist.
  local ok = pcall(vim.api.nvim_get_autocmds, { group = name })
  return ok
end

--- Create a temp file of `size` bytes and return its path.
---@param size integer
---@return string
local function make_file(size)
  local path = vim.fn.tempname()
  local fd = assert(vim.loop.fs_open(path, "w", 420))
  vim.loop.fs_write(fd, string.rep("a", size))
  vim.loop.fs_close(fd)
  return path
end

describe("largefile setup", function()
  after_each(function()
    largefile.disable()
  end)

  it("installs detection autocmds when enabled", function()
    largefile.setup({ notify = false })
    assert.is_true(augroup_exists("keystone.largefile"))
  end)

  it("installs nothing when enabled = false", function()
    largefile.setup({ enabled = false })
    assert.is_false(augroup_exists("keystone.largefile"))
  end)
end)

describe("largefile detection", function()
  after_each(function()
    largefile.disable()
  end)

  it("marks a file above the size threshold", function()
    largefile.setup({ size_threshold = 1024, notify = false })
    local path = make_file(4096)

    vim.cmd.edit(vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()

    assert.is_true(largefile.is_large(bufnr))
    assert.is_false(vim.bo[bufnr].swapfile)

    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.loop.fs_unlink(path)
  end)

  it("leaves a small file untouched", function()
    largefile.setup({ size_threshold = 1024 * 1024, notify = false })
    local path = make_file(64)

    vim.cmd.edit(vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()

    assert.is_false(largefile.is_large(bufnr))

    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.loop.fs_unlink(path)
  end)

  it("can force a buffer into large-file mode via mark", function()
    largefile.setup({ size_threshold = 1024 * 1024, notify = false })
    local bufnr = vim.api.nvim_create_buf(true, false)

    largefile.mark(bufnr)
    assert.is_true(largefile.is_large(bufnr))

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
