local marksigns = require("keystone.marksigns")

local function augroup_exists(name)
  -- nvim_get_autocmds errors when the group does not exist.
  local ok = pcall(vim.api.nvim_get_autocmds, { group = name })
  return ok
end

---@return integer
local function namespace()
  return assert(vim.api.nvim_get_namespaces()["keystone.marksigns"])
end

--- The mark signs in `bufnr`, as `{ [lnum] = { text, hl } }` with 1-based lines.
--- Neovim pads `sign_text` to the two cells of the sign column, so the text is
--- trimmed back to the mark names that were asked for.
---@param bufnr integer?
---@return table<integer, string[]>
local function signs(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local out = {}
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, namespace(), 0, -1, { details = true })
  for _, m in ipairs(extmarks) do
    out[m[2] + 1] = { vim.trim(m[4].sign_text), m[4].sign_hl_group }
  end
  return out
end

--- Open a scratch file with `lines` and return its buffer and path. `MarkSet`
--- only fires for real, listed buffers, so this goes through a written file
--- rather than a nofile scratch buffer.
---@param lines string[]
---@return integer bufnr, string path
local function open_file(lines)
  local path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile(lines, path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf(), path
end

--- `MarkSet` is dispatched from the event loop rather than from `m` itself, so
--- tests have to let it drain before asserting.
---@param predicate fun(): boolean
local function wait_for(predicate)
  vim.wait(1000, predicate, 10)
end

---@param lnum integer
---@param name string
local function set_mark(lnum, name)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.cmd("normal! m" .. name)
end

--- Announce that `bufnr` was edited. Neovim fires `TextChanged` from the
--- normal-mode input loop, which a headless script never returns to, so a test
--- that edits the buffer has to dispatch the event itself.
---@param bufnr integer
local function edited(bufnr)
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
end

describe("marksigns setup", function()
  after_each(function()
    marksigns.disable()
  end)

  it("installs the autocmds when enabled", function()
    marksigns.setup()
    assert.is_true(augroup_exists("keystone.marksigns"))
    assert.is_true(marksigns.is_enabled())
  end)

  it("installs nothing when enabled = false", function()
    marksigns.setup({ enabled = false })
    assert.is_false(marksigns.is_enabled())
    assert.same({}, vim.api.nvim_get_autocmds({ group = "keystone.marksigns" }))
  end)
end)

describe("marksigns signs", function()
  local bufnr, path

  before_each(function()
    marksigns.setup()
    bufnr, path = open_file({ "one", "two", "three", "four", "five" })
  end)

  after_each(function()
    marksigns.disable()
    vim.cmd("delmarks! | delmarks A-Z")
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.fn.delete(path)
  end)

  it("signs a local mark when MarkSet fires", function()
    set_mark(2, "a")
    wait_for(function() return signs()[2] ~= nil end)

    assert.same({ "a", "KeystoneMarkSignsLocal" }, signs()[2])
    assert.is_nil(signs()[1])
  end)

  it("removes the sign when the mark is deleted", function()
    set_mark(2, "a")
    wait_for(function() return signs()[2] ~= nil end)

    vim.cmd("delmarks a")
    wait_for(function() return signs()[2] == nil end)

    assert.is_nil(signs()[2])
  end)

  it("moves the sign when the mark is set again elsewhere", function()
    set_mark(2, "a")
    wait_for(function() return signs()[2] ~= nil end)

    set_mark(4, "a")
    wait_for(function() return signs()[4] ~= nil end)

    assert.is_nil(signs()[2])
    assert.same({ "a", "KeystoneMarkSignsLocal" }, signs()[4])
  end)

  it("signs a global mark with its own highlight", function()
    set_mark(3, "Z")
    wait_for(function() return signs()[3] ~= nil end)

    assert.same({ "Z", "KeystoneMarkSignsGlobal" }, signs()[3])
  end)

  it("combines two marks on one line into a single sign", function()
    set_mark(2, "b")
    set_mark(2, "a")
    wait_for(function() return signs()[2] and signs()[2][1] == "ab" end)

    -- Ordered by `config.marks`, not by the order they were set.
    assert.same({ "ab", "KeystoneMarkSignsLocal" }, signs()[2])
  end)

  it("shows only the marks named in config.marks", function()
    marksigns.setup({ marks = "ab" })

    set_mark(2, "c")
    set_mark(3, "b")
    wait_for(function() return signs()[3] ~= nil end)

    assert.is_nil(signs()[2])
    assert.same({ "b", "KeystoneMarkSignsLocal" }, signs()[3])
  end)

  it("drops the sign when the marked line is deleted", function()
    set_mark(2, "a")
    wait_for(function() return signs()[2] ~= nil end)

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("normal! dd")
    -- Deleting the line drops the mark without a MarkSet, so the debounced
    -- TextChanged recompute is what clears the sign. Neovim only fires
    -- TextChanged from the normal-mode input loop, which a headless script
    -- never reaches, so the event is dispatched here by hand.
    edited(bufnr)
    wait_for(function() return next(signs()) == nil end)

    assert.same({}, signs())
  end)

  it("keeps signs of surviving marks after an edit", function()
    set_mark(2, "a")
    set_mark(4, "b")
    wait_for(function() return signs()[4] ~= nil end)

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! dd")
    edited(bufnr)
    wait_for(function() return signs()[3] ~= nil end)

    assert.same({ "a", "KeystoneMarkSignsLocal" }, signs()[1])
    assert.same({ "b", "KeystoneMarkSignsLocal" }, signs()[3])
  end)

  it("clears every sign on disable", function()
    set_mark(2, "a")
    wait_for(function() return signs()[2] ~= nil end)

    marksigns.disable()

    assert.same({}, signs())
    assert.is_false(marksigns.is_enabled())
  end)

  it("re-signs existing marks on enable", function()
    set_mark(2, "a")
    wait_for(function() return signs()[2] ~= nil end)

    marksigns.disable()
    assert.same({}, signs())

    marksigns.enable()
    assert.same({ "a", "KeystoneMarkSignsLocal" }, signs()[2])
  end)
end)

describe("marksigns buffer selection", function()
  after_each(function()
    marksigns.disable()
    vim.cmd("delmarks!")
  end)

  it("leaves special buffers alone", function()
    marksigns.setup()

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two" })
    vim.api.nvim_buf_set_mark(bufnr, "a", 2, 0, {})

    marksigns.refresh(bufnr)
    assert.same({}, signs(bufnr))

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
