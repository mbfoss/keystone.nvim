local items = require("keystone.lspcompletion.items")

local CIK = vim.lsp.protocol.CompletionItemKind
local ITF = vim.lsp.protocol.InsertTextFormat
local DEPRECATED = vim.lsp.protocol.CompletionTag.Deprecated

describe("items.filter_word", function()
    it("prefers filterText over label", function()
        assert.are.equal("F", items.filter_word({ label = "L", filterText = "F" }))
    end)

    it("falls back to label", function()
        assert.are.equal("L", items.filter_word({ label = "L" }))
    end)
end)

describe("items.word", function()
    it("prefers textEdit.newText, then insertText, then filter word", function()
        assert.are.equal("N", items.word({ label = "L", insertText = "I", textEdit = { newText = "N" } }))
        assert.are.equal("I", items.word({ label = "L", insertText = "I" }))
        assert.are.equal("L", items.word({ label = "L" }))
    end)

    it("returns empty string when nothing is present", function()
        assert.are.equal("", items.word({}))
    end)
end)

describe("items.is_snippet_body", function()
    it("is false for a plain identifier", function()
        assert.is_false(items.is_snippet_body("foo"))
    end)

    it("is true for a placeholder or tab stop", function()
        assert.is_true(items.is_snippet_body("${1:bar}"))
        assert.is_true(items.is_snippet_body("fn(${1:a})"))
        assert.is_true(items.is_snippet_body("$0"))
    end)

    it("is true when the body spans multiple lines or has a tab", function()
        assert.is_true(items.is_snippet_body("line1\nline2"))
        assert.is_true(items.is_snippet_body("a\tb"))
    end)

    it("is false for an escaped leading dollar", function()
        assert.is_false(items.is_snippet_body("\\$foo"))
    end)
end)

describe("items.apply_defaults", function()
    it("returns items untouched when defaults is not a table", function()
        local src = { { label = "x" } }
        assert.are.equal(src, items.apply_defaults(src, nil))
    end)

    it("fills missing fields but never overrides existing ones", function()
        local list = { { label = "foo", insertTextFormat = 99 } }
        items.apply_defaults(list, { insertTextFormat = 2, data = { d = 1 } })
        assert.are.equal(99, list[1].insertTextFormat) -- kept
        assert.are.same({ d = 1 }, list[1].data)       -- filled
    end)

    it("applies an editRange default into textEdit", function()
        local range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 3 } }
        local list  = { { label = "foo" } }
        items.apply_defaults(list, { editRange = range })
        assert.are.equal("foo", list[1].textEdit.newText) -- from label
        assert.are.same(range, list[1].textEdit.range)
    end)
end)

describe("items.to_vim", function()
    it("returns an empty list for no items", function()
        assert.are.same({}, items.to_vim({}))
    end)

    it("maps a plain item, joining label details into the menu", function()
        local out = items.to_vim({
            { label = "foo", insertText = "foo", kind = CIK.Function,
              labelDetails = { detail = "(int)", description = "mymod" } },
        })
        assert.are.equal(1, #out)
        assert.are.equal("foo", out[1].word)
        assert.are.equal("foo", out[1].abbr)
        assert.are.equal("Function", out[1].kind)
        assert.are.equal("(int) mymod", out[1].menu)
        assert.is_nil(out[1].info)
        assert.is_false(out[1].user_data.lsp.needs_snippet_insert)
        assert.are.equal(1, out[1].user_data.lsp.item_id)
    end)

    it("detects a snippet: word is the filter word, body goes to info", function()
        local out = items.to_vim({
            { label = "fn", filterText = "fn", kind = CIK.Snippet,
              insertTextFormat = ITF.Snippet, textEdit = { newText = "fn(${1:a})" } },
        })
        assert.are.equal("fn", out[1].word)          -- inserted verbatim, expanded later
        assert.are.equal("fn(${1:a})", out[1].info)   -- snippet body
        assert.are.equal("S", out[1].menu)
        assert.is_true(out[1].user_data.lsp.needs_snippet_insert)
    end)

    it("does not treat a snippet-flagged plain body as a snippet", function()
        local out = items.to_vim({
            { label = "foo", insertText = "foo", kind = CIK.Snippet, insertTextFormat = ITF.Snippet },
        })
        assert.is_false(out[1].user_data.lsp.needs_snippet_insert)
        assert.are.equal("foo", out[1].word)
    end)
end)

describe("items.sort_by_kind", function()
    it("orders by priority (desc), stable by index, dropping negatives", function()
        local list = {
            { label = "a", kind = CIK.Variable },
            { label = "b", kind = CIK.Function },
            { label = "c", kind = CIK.Variable },
            { label = "d", kind = CIK.Snippet },
        }
        local out    = items.sort_by_kind(list, { Function = 10, Variable = 5, Snippet = -1 })
        local labels = vim.tbl_map(function(i) return i.label end, out)
        assert.are.same({ "b", "a", "c" }, labels)
    end)
end)

describe("items.add_hlgroups", function()
    it("flags deprecated items via the field or the tags list", function()
        local list = {
            { label = "x", deprecated = true },
            { label = "y", tags = { DEPRECATED } },
            { label = "z" },
        }
        items.add_hlgroups(list)
        assert.are.equal("KeystoneCompletionDeprecated", list[1].abbr_hlgroup)
        assert.are.equal("KeystoneCompletionDeprecated", list[2].abbr_hlgroup)
        assert.is_nil(list[3].abbr_hlgroup)
    end)
end)

describe("items.filter_sort", function()
    it("returns a copy of everything for an empty base", function()
        local src = { { label = "foo" } }
        local out = items.filter_sort(src, "")
        assert.are.equal(1, #out)
        assert.are_not.equal(src[1], out[1]) -- deep-copied, not aliased
    end)

    it("keeps only items whose filter word is prefixed by base", function()
        local src    = { { label = "foo" }, { label = "foobar" }, { label = "baz" } }
        local labels = vim.tbl_map(function(i) return i.label end, items.filter_sort(src, "foo"))
        assert.are.same({ "foo", "foobar" }, labels)
    end)
end)
