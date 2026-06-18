local qf = require("keystone.pick.base.queryflags")

local schema = {
    { name = "path",  type = "value", values = { "foo", "foo bar", "baz" } },
    { name = "kind",  type = "value", multi = true },
    { name = "fixed", type = "boolean" },
}

describe("queryflags query", function()
    it("treats plain words as the query", function()
        local r = qf.parse(schema, "hello world")
        assert.are.equal("hello world", r.query)
        assert.are.same({}, r.flags)
    end)

    it("pulls flags out from anywhere, leaving the rest as the query", function()
        local r = qf.parse(schema, "is:fixed hello path:src world")
        assert.is_true(r.flags.fixed)
        assert.are.equal("src", r.flags.path)
        assert.are.equal("hello world", r.query)
    end)

    it("accepts flags and query in any order", function()
        local r = qf.parse(schema, "hello path:src is:fixed world")
        assert.is_true(r.flags.fixed)
        assert.are.equal("src", r.flags.path)
        assert.are.equal("hello world", r.query)
    end)

    it("keeps a quoted query token with spaces as one piece", function()
        local r = qf.parse(schema, 'is:fixed "foo bar" baz')
        assert.is_true(r.flags.fixed)
        assert.are.equal("foo bar baz", r.query)
    end)

    it("yields an empty query when only flags are present", function()
        local r = qf.parse(schema, "is:fixed path:src")
        assert.is_true(r.flags.fixed)
        assert.are.equal("src", r.flags.path)
        assert.are.equal("", r.query)
    end)
end)

describe("queryflags quoting as a flag escape", function()
    it("treats a quoted boolean flag as query text", function()
        local r = qf.parse(schema, '"is:fixed" hello')
        assert.is_nil(r.flags.fixed)
        assert.are.equal("is:fixed hello", r.query)
    end)

    it("treats a quoted key:value token as query text", function()
        local r = qf.parse(schema, '"path:foo" bar')
        assert.is_nil(r.flags.path)
        assert.are.equal("path:foo bar", r.query)
    end)

    it("leaves an unknown key:value token in the query", function()
        local r = qf.parse(schema, "http://example.com here")
        assert.are.same({}, r.flags)
        assert.are.equal("http://example.com here", r.query)
    end)
end)

describe("queryflags boolean flags", function()
    it("sets a boolean flag via the is: prefix", function()
        local r = qf.parse(schema, "is:fixed hello world")
        assert.is_true(r.flags.fixed)
        assert.are.equal("hello world", r.query)
    end)

    it("treats a bare boolean flag name as query text", function()
        local r = qf.parse(schema, "fixed hello world")
        assert.is_nil(r.flags.fixed)
        assert.are.equal("fixed hello world", r.query)
    end)

    it("leaves an unknown is: token in the query", function()
        local r = qf.parse(schema, "is:nope hello")
        assert.is_nil(r.flags.nope)
        assert.are.equal("is:nope hello", r.query)
    end)
end)

describe("queryflags value flags", function()
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

    it("keeps an unterminated value quote as a literal char", function()
        local r = qf.parse(schema, 'path:"foo ba')
        -- the key is unquoted so it is still a value flag; the unterminated
        -- quote survives as a literal char in the value (mid-typing).
        assert.are.equal('"foo ba', r.flags.path)
        assert.are.equal("", r.query)
    end)

    it("keeps a fully unterminated quote out of the flags", function()
        local r = qf.parse(schema, '"foo ba')
        -- a quote opening the token quotes the whole thing: query text.
        assert.are.same({}, r.flags)
        assert.are.equal('"foo ba', r.query)
    end)

    it("collects quoted values for multi flags", function()
        local r = qf.parse(schema, 'kind:"a b" kind:c')
        assert.are.same({ "a b", "c" }, r.flags.kind)
    end)

    it("consumes a value flag with an empty value", function()
        local r = qf.parse(schema, "path: here")
        assert.is_nil(r.flags.path)
        assert.are.equal("here", r.query)
    end)
end)

describe("queryflags highlight", function()
    it("highlights flags wherever they appear", function()
        local hls = qf.highlight(schema, "hello is:fixed path:foo")
        local has_keyword = false
        local has_string  = false
        for _, h in ipairs(hls) do
            if h.hl == "Keyword" then has_keyword = true end
            if h.hl == "String" then has_string = true end
        end
        assert.is_true(has_keyword)
        assert.is_true(has_string)
    end)

    it("does not highlight quoted (escaped) flag tokens", function()
        assert.are.same({}, qf.highlight(schema, '"is:fixed" "path:foo"'))
    end)
end)

describe("queryflags completion", function()
    it("completes a partial is:<boolean> token", function()
        local comps = qf.get_completions(schema, "is:fi", 5)
        assert.is_not_nil(comps)
        local found = false
        for _, item in ipairs(comps.items) do
            if item.word == "is:fixed" then found = true end
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
