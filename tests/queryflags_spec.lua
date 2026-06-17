local qf = require("keystone.pick.base.queryflags")

local schema = {
    { name = "path",  type = "value", values = { "foo", "foo bar", "baz" } },
    { name = "kind",  type = "value", multi = true },
    { name = "fixed", type = "boolean" },
}

describe("queryflags separator", function()
    it("treats the whole input as a literal query when no separator is present", function()
        local r = qf.parse(schema, "hello world")
        assert.are.equal("hello world", r.query)
        assert.are.same({}, r.flags)
    end)

    it("does not require quoting in the query", function()
        local r = qf.parse(schema, 'fixed -- path:"foo bar" baz')
        assert.is_true(r.flags.fixed)
        assert.are.equal('path:"foo bar" baz', r.query)
    end)

    it("strips only the whitespace immediately following the separator", function()
        local r = qf.parse(schema, "fixed --   leading kept")
        assert.are.equal("leading kept", r.query)
    end)

    it("yields an empty query when nothing follows the separator", function()
        local r = qf.parse(schema, "fixed --")
        assert.is_true(r.flags.fixed)
        assert.are.equal("", r.query)
    end)

    it("forces a literal query with a leading separator", function()
        local r = qf.parse(schema, "-- fixed path:x")
        assert.are.same({}, r.flags)
        assert.are.equal("fixed path:x", r.query)
    end)

    it("treats a quoted separator as a flag token, not the separator", function()
        local r = qf.parse(schema, 'fixed "--" -- query')
        assert.is_true(r.flags.fixed)
        assert.are.equal("query", r.query)
    end)
end)

describe("queryflags boolean flags", function()
    it("sets a bare boolean flag name in the flags prefix", function()
        local r = qf.parse(schema, "fixed -- hello world")
        assert.is_true(r.flags.fixed)
        assert.are.equal("hello world", r.query)
    end)

    it("ignores an unknown bare token in the flags prefix", function()
        local r = qf.parse(schema, "nope -- hello")
        assert.is_nil(r.flags.nope)
        assert.are.equal("hello", r.query)
    end)

    it("treats a boolean name as query text without a separator", function()
        local r = qf.parse(schema, "fixed")
        assert.is_nil(r.flags.fixed)
        assert.are.equal("fixed", r.query)
    end)
end)

describe("queryflags value flags", function()
    it("parses a double-quoted value with spaces", function()
        local r = qf.parse(schema, 'path:"foo bar" --')
        assert.are.equal("foo bar", r.flags.path)
        assert.are.equal("", r.query)
    end)

    it("parses a single-quoted value with spaces", function()
        local r = qf.parse(schema, "path:'foo bar' --")
        assert.are.equal("foo bar", r.flags.path)
        assert.are.equal("", r.query)
    end)

    it("keeps an unterminated quote as a literal char", function()
        local r = qf.parse(schema, 'path:"foo ba --')
        -- the unterminated quote swallows the rest of the prefix, so there is
        -- no separator and the whole input is the literal query.
        assert.is_nil(r.flags.path)
        assert.are.equal('path:"foo ba --', r.query)
    end)

    it("collects quoted values for multi flags", function()
        local r = qf.parse(schema, 'kind:"a b" kind:c --')
        assert.are.same({ "a b", "c" }, r.flags.kind)
    end)

    it("ignores a value flag with an empty value", function()
        local r = qf.parse(schema, "path: --")
        assert.is_nil(r.flags.path)
    end)
end)

describe("queryflags highlight", function()
    it("does not highlight anything without a separator", function()
        assert.are.same({}, qf.highlight(schema, "fixed path:foo"))
    end)

    it("highlights flags and the separator", function()
        local hls = qf.highlight(schema, "fixed -- query")
        local has_delimiter = false
        local has_keyword   = false
        for _, h in ipairs(hls) do
            if h.hl == "Delimiter" then has_delimiter = true end
            if h.hl == "Keyword" then has_keyword = true end
        end
        assert.is_true(has_delimiter)
        assert.is_true(has_keyword)
    end)
end)

describe("queryflags completion", function()
    it("completes a bare boolean name in the flags prefix", function()
        local comps = qf.get_completions(schema, "fi", 2)
        assert.is_not_nil(comps)
        local found = false
        for _, item in ipairs(comps.items) do
            if item.word == "fixed" then found = true end
        end
        assert.is_true(found)
    end)

    it("offers value-flag key prefixes", function()
        local comps = qf.get_completions(schema, "pa", 2)
        assert.is_not_nil(comps)
        local found = false
        for _, item in ipairs(comps.items) do
            if item.word == "path:" then found = true end
        end
        assert.is_true(found)
    end)

    it("suppresses bare-word completions when auto is set", function()
        assert.is_nil(qf.get_completions(schema, "fi", 2, true))
    end)

    it("stops completing once the separator is present", function()
        assert.is_nil(qf.get_completions(schema, "fixed -- pa", #"fixed -- pa"))
    end)

    it("offers the separator when typing a dash", function()
        local comps = qf.get_completions(schema, "fixed -", #"fixed -")
        assert.is_not_nil(comps)
        local found = false
        for _, item in ipairs(comps.items) do
            if item.word == "--" then found = true end
        end
        assert.is_true(found)
    end)

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

        local r = qf.parse(schema, spaced.word .. " --")
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
