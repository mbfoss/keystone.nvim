local symbols = require("keystone.symboltree.symbols")
local kinds = require("keystone.symboltree.kinds")

---@param sl integer
---@param sc integer
---@param el integer
---@param ec integer
local function range(sl, sc, el, ec)
    return { start = { line = sl, character = sc }, ["end"] = { line = el, character = ec } }
end

describe("symboltree.symbols.normalize", function()
    it("converts DocumentSymbol positions to 1-based lines", function()
        local out = symbols.normalize({
            { name = "foo", kind = 12, range = range(0, 0, 4, 3), selectionRange = range(0, 9, 0, 12) },
        })
        assert.equals(1, #out)
        assert.equals("foo", out[1].name)
        assert.equals(1, out[1].lnum)
        assert.equals(5, out[1].end_lnum)
    end)

    it("takes the cursor position from selectionRange, not range", function()
        local out = symbols.normalize({
            { name = "foo", kind = 12, range = range(0, 0, 4, 3), selectionRange = range(0, 9, 0, 12) },
        })
        -- range starts at column 0 ("function"), selectionRange at the name
        assert.equals(9, out[1].col)
    end)

    it("nests children recursively", function()
        local out = symbols.normalize({
            {
                name = "Klass",
                kind = 5,
                range = range(0, 0, 20, 0),
                children = {
                    { name = "method", kind = 6, range = range(2, 2, 5, 2) },
                },
            },
        })
        assert.equals(1, #out)
        assert.equals(1, #out[1].children)
        assert.equals("method", out[1].children[1].name)
        assert.equals(3, out[1].children[1].lnum)
    end)

    it("handles the flat SymbolInformation shape", function()
        local out = symbols.normalize({
            { name = "bar", kind = 12, location = { uri = "file:///x", range = range(6, 0, 9, 1) } },
        })
        assert.equals(1, #out)
        assert.equals("bar", out[1].name)
        assert.equals(7, out[1].lnum)
        assert.equals(10, out[1].end_lnum)
    end)

    it("sorts siblings by position at every depth", function()
        local out = symbols.normalize({
            { name = "second", kind = 12, range = range(10, 0, 12, 0) },
            { name = "first",  kind = 12, range = range(1, 0, 3, 0) },
            {
                name = "third",
                kind = 5,
                range = range(20, 0, 30, 0),
                children = {
                    { name = "b", kind = 6, range = range(25, 0, 26, 0) },
                    { name = "a", kind = 6, range = range(21, 0, 22, 0) },
                },
            },
        })
        assert.equals("first", out[1].name)
        assert.equals("second", out[2].name)
        assert.equals("third", out[3].name)
        assert.equals("a", out[3].children[1].name)
        assert.equals("b", out[3].children[2].name)
    end)

    it("drops entries with no usable range", function()
        local out = symbols.normalize({
            { name = "no_range", kind = 12 },
            { name = "ok", kind = 12, range = range(0, 0, 1, 0) },
        })
        assert.equals(1, #out)
        assert.equals("ok", out[1].name)
    end)

    it("returns an empty list for nil or empty input", function()
        assert.equals(0, #symbols.normalize(nil))
        assert.equals(0, #symbols.normalize({}))
    end)
end)

describe("symboltree.symbols.path_at_line", function()
    local tree = symbols.normalize({
        {
            name = "Klass",
            kind = 5,
            range = range(0, 0, 20, 0),
            children = {
                { name = "method", kind = 6, range = range(2, 0, 5, 0) },
                { name = "other",  kind = 6, range = range(8, 0, 12, 0) },
            },
        },
    })

    it("returns the innermost enclosing symbol path", function()
        local path = symbols.path_at_line(tree, 4)
        assert.equals(2, #path)
        assert.equals("Klass", path[1].name)
        assert.equals("method", path[2].name)
    end)

    it("stops at the parent when no child encloses the line", function()
        local path = symbols.path_at_line(tree, 7)
        assert.equals(1, #path)
        assert.equals("Klass", path[1].name)
    end)

    it("returns an empty path outside every range", function()
        assert.equals(0, #symbols.path_at_line(tree, 100))
    end)
end)

describe("symboltree.kinds", function()
    it("maps every LSP SymbolKind code 1..26", function()
        for code = 1, 26 do
            assert.not_nil(kinds.kinds[code])
            assert.is_truthy(kinds.get(code).name)
        end
    end)

    it("falls back for an unknown kind", function()
        assert.equals("Unknown", kinds.get(99).name)
        assert.equals("Unknown", kinds.get(nil).name)
    end)
end)
