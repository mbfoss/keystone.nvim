local keystone = require("keystone")
local health = require("keystone.health")
local largefile = require("keystone.largefile")

--- Run `health.check()` with `vim.health` stubbed, returning the reported
--- entries as `{ level, message }` pairs.
---@return table[]
local function capture()
  local entries = {}
  local saved = {}
  -- `keystone.health` holds a reference to the `vim.health` table, so the
  -- functions on it are what must be swapped, not the table itself.
  for _, level in ipairs({ "start", "ok", "info", "warn", "error" }) do
    saved[level] = vim.health[level]
    vim.health[level] = function(msg)
      table.insert(entries, { level = level, message = msg })
    end
  end
  local ok, err = pcall(health.check)
  for level, fn in pairs(saved) do
    vim.health[level] = fn
  end
  assert(ok, err)
  return entries
end

--- All messages reported at `level`, joined.
---@param entries table[]
---@param level string
---@return string
local function messages(entries, level)
  local out = {}
  for _, entry in ipairs(entries) do
    if entry.level == level then table.insert(out, entry.message) end
  end
  return table.concat(out, "\n")
end

--- The messages reported under the `section` heading, joined.
---@param entries table[]
---@param section string
---@return string?
local function section(entries, section_name)
  local out
  for _, entry in ipairs(entries) do
    if entry.level == "start" then
      if out then return table.concat(out, "\n") end
      out = entry.message == section_name and {} or nil
    elseif out then
      table.insert(out, entry.message)
    end
  end
  return out and table.concat(out, "\n")
end

describe("keystone.health", function()
  after_each(function()
    largefile.disable()
    package.loaded["keystone.largefile"] = largefile
  end)

  it("lists a module whose setup() has run as active", function()
    keystone.setup({ largefile = true })
    assert.matches("active: [^\n]*largefile", messages(capture(), "info"))
  end)

  it("lists a loaded but un-setup module as inactive", function()
    -- A module that setup() has run for earlier in this session stays active,
    -- so the un-setup case needs a module standing in for a fresh require.
    package.loaded["keystone.largefile"] = { is_setup = function() return false end }
    assert.matches("inactive: [^\n]*largefile", messages(capture(), "info"))
  end)

  it("lists an unloaded module as inactive", function()
    package.loaded["keystone.largefile"] = nil
    assert.matches("inactive: [^\n]*largefile", messages(capture(), "info"))
  end)

  it("gives a module at its defaults no section", function()
    keystone.setup({ largefile = true })
    assert.is_nil(section(capture(), "keystone.largefile"))
  end)

  it("sections a modified module with only the changed options", function()
    keystone.setup({ largefile = { size_threshold = 4242 } })
    local reported = section(capture(), "keystone.largefile")
    assert.matches("size_threshold = 4242", reported)
    assert.is_nil(reported:match("notify"))
  end)

  it("flags an option the module does not define", function()
    keystone.setup({ largefile = { size_treshold = 4242 } })
    assert.matches("size_treshold", messages(capture(), "warn"))
  end)
end)
