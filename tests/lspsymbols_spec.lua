local symbols = require("keystone.util.lspsymbols")

---@param sl integer
---@param sc integer
---@param el integer
---@param ec integer
local function range(sl, sc, el, ec)
    return { start = { line = sl, character = sc }, ["end"] = { line = el, character = ec } }
end

describe("lspsymbols.normalize", function()
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

    it("rebuilds a hierarchy from a flat SymbolInformation list by containment", function()
        -- Shape returned by servers like pylsp: a flat list where nesting is
        -- implied by range containment rather than a `children` field.
        local out = symbols.normalize({
            { name = "meth", kind = 6, location = { uri = "file:///x", range = range(2, 4, 5, 0) } },
            { name = "Klass", kind = 5, location = { uri = "file:///x", range = range(0, 0, 8, 0) } },
            { name = "top", kind = 12, location = { uri = "file:///x", range = range(10, 0, 12, 0) } },
        })
        assert.equals(2, #out)
        assert.equals("Klass", out[1].name)
        assert.equals(1, #out[1].children)
        assert.equals("meth", out[1].children[1].name)
        assert.equals("top", out[2].name)
        assert.equals(0, #out[2].children)
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

describe("lspsymbols.path_at_line", function()
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

describe("lspsymbols.place", function()
    it("places the shapes a symbol-like item arrives in", function()
        -- DocumentSymbol, CallHierarchyItem: range and selectionRange directly.
        local direct = symbols.place({ name = "f", kind = 12, range = range(2, 0, 4, 3), selectionRange = range(2, 9, 2, 12) })
        assert.equals(3, direct.lnum)
        assert.equals(9, direct.col)
        assert.equals(5, direct.end_lnum)

        -- SymbolInformation: one range, nested under location.
        local nested = symbols.place({ name = "g", kind = 12, location = { uri = "file:///x", range = range(6, 0, 9, 1) } })
        assert.equals(7, nested.lnum)
        assert.equals(0, nested.col)
        assert.equals(10, nested.end_lnum)
    end)

    it("falls back to the full range for the cursor position", function()
        local placed = symbols.place({ name = "h", kind = 12, range = range(1, 4, 3, 9) })
        assert.equals(2, placed.lnum)
        assert.equals(4, placed.col)
    end)

    it("turns down an entry it cannot place", function()
        assert.is_nil(symbols.place({ name = "no_range", kind = 12 }))
        assert.is_nil(symbols.place({ kind = 12, range = { start = { line = 0 } } }))
        assert.is_nil(symbols.place("not a table"))
    end)

    it("gives the same placement whichever entry point is used", function()
        local raw = { name = "klass", kind = 5, range = range(0, 0, 20, 1), selectionRange = range(0, 6, 0, 11) }
        local placed, normalized = symbols.place(raw), symbols.normalize({ raw })[1]
        for _, field in ipairs({ "name", "detail", "kind", "lnum", "col", "end_lnum" }) do
            assert.equals(placed[field], normalized[field], field)
        end
    end)
end)

describe("lspsymbols load", function()
    -- The module is shared by `keystone.symboltree` and `keystone.lspsetup`, so
    -- loading it must not choose a side: no feature module may come with it, and
    -- nothing may be registered behind the caller's back.
    it("pulls in no other module", function()
        package.loaded["keystone.util.lspsymbols"] = nil
        local before = {}
        for name in pairs(package.loaded) do before[name] = true end

        require("keystone.util.lspsymbols")

        for name in pairs(package.loaded) do
            if name ~= "keystone.util.lspsymbols" then
                assert.is_true(before[name], "loading lspsymbols also loaded " .. name)
            end
        end
    end)

    it("registers no autocmd", function()
        local count = #vim.api.nvim_get_autocmds({})
        require("keystone.util.lspsymbols")
        assert.equals(count, #vim.api.nvim_get_autocmds({}))
    end)
end)
