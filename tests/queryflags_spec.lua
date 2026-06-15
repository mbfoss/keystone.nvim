local qf = require("keystone.pick.base.queryflags")

local schema = {
    { name = "path",  type = "value", values = { "foo", "foo bar", "baz" } },
    { name = "kind",  type = "value", multi = true },
    { name = "fixed", type = "boolean" },
}

describe("queryflags quoted values", function()
    it("parses a double-quoted value with spaces", function()
        local r = qf.parse(schema, 'path:"foo bar"')
        assert.are.equal("foo bar", r.flags.path)
        assert.are.equal("", r.query)
    end)

    it("parses a single-quoted value with spaces", function()
        local r = qf.parse(schema, "path:'foo bar'")
        assert.are.equal("foo bar", r.flags.path)
        assert.are.equal("", r.query)
    end)

    it("keeps surrounding query tokens separate from the quoted value", function()
        local r = qf.parse(schema, 'hello path:"foo bar" world')
        assert.are.equal("foo bar", r.flags.path)
        assert.are.equal("hello world", r.query)
    end)

    it("treats an unterminated quote as running to end of string", function()
        local r = qf.parse(schema, 'path:"foo ba')
        assert.are.equal("foo ba", r.flags.path)
        assert.are.equal("", r.query)
    end)

    it("does not treat quotes as special outside a value", function()
        local r = qf.parse(schema, '"foo bar"')
        assert.are.equal('"foo bar"', r.query)
        assert.is_nil(r.flags.path)
    end)

    it("collects quoted values for multi flags", function()
        local r = qf.parse(schema, 'kind:"a b" kind:c')
        assert.are.same({ "a b", "c" }, r.flags.kind)
    end)
end)

describe("queryflags completion round-trip", function()
    it("wraps a spaced value in quotes so it re-parses", function()
        local line  = "path:foo"
        local comps = qf.get_completions(schema, line, #line)
        assert.is_not_nil(comps)

        local spaced
        for _, item in ipairs(comps.items) do
            if item.abbr == "foo bar" then spaced = item end
        end
        assert.is_not_nil(spaced)
        assert.are.equal('path:"foo bar"', spaced.word)

        -- the inserted word must parse back to the original value
        local r = qf.parse(schema, spaced.word)
        assert.are.equal("foo bar", r.flags.path)
    end)

    it("offers value completions while inside an open quote", function()
        local line  = 'path:"foo '
        local comps = qf.get_completions(schema, line, #line)
        assert.is_not_nil(comps)

        local found = false
        for _, item in ipairs(comps.items) do
            if item.abbr == "foo bar" then found = true end
        end
        assert.is_true(found)
    end)
end)
