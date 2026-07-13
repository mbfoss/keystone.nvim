local completion = require("keystone.completion")

local is_snippet_item = completion._is_snippet_item

--- Build a completion entry carrying an LSP completion item.
---@param insert_text_format? integer
---@return table
local function lsp_item(insert_text_format)
  return {
    word = "print",
    user_data = { nvim = { lsp = { completion_item = { insertTextFormat = insert_text_format } } } },
  }
end

describe("completion._is_snippet_item", function()
  local SNIPPET = vim.lsp.protocol.InsertTextFormat.Snippet
  local PLAIN   = vim.lsp.protocol.InsertTextFormat.PlainText

  it("recognizes an LSP snippet entry", function()
    assert.is_true(is_snippet_item(lsp_item(SNIPPET)))
  end)

  it("treats a plaintext LSP entry as not a snippet", function()
    assert.is_false(is_snippet_item(lsp_item(PLAIN)))
  end)

  it("treats non-LSP entries (string / missing user_data) as not a snippet", function()
    assert.is_false(is_snippet_item({ word = "foo", user_data = "" }))
    assert.is_false(is_snippet_item({ word = "foo" }))
    assert.is_false(is_snippet_item(nil))
  end)
end)

describe("completion.setup", function()
  it("enables commit_on_char by default and maps no commit chars", function()
    completion.setup({})
    assert.is_true(completion.config.commit_on_char)
    -- '(' must NOT be mapped -- the commit_on_char path needs no key mappings
    -- (that is the whole point: no clash with autopairs).
    assert.is_true(vim.tbl_isempty(vim.fn.maparg("(", "i", false, true)))
  end)
end)
