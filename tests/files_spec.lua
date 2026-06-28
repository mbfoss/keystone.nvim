local files = require("keystone.pick.pickers.files")
local regex = require("keystone.util.regex")

local resolve_case = files._resolve_case
local do_match     = files._do_match

describe("resolve_case", function()
    it("honors explicit on/off", function()
        assert.is_true(resolve_case("on", "foo", false))
        assert.is_false(resolve_case("off", "FOO", false))
    end)

    it("smart-cases on uppercase for literal text", function()
        assert.is_false(resolve_case("smart", "foo", false))
        assert.is_true(resolve_case("smart", "Foo", false))
        assert.is_false(resolve_case(nil, "foo", false))
    end)

    it("degrades to insensitive for regex unless forced on", function()
        assert.is_false(resolve_case(nil, "Foo", true))
        assert.is_false(resolve_case("smart", "FOO", true))
        assert.is_true(resolve_case("on", "foo", true))
    end)
end)

describe("do_match (regex)", function()
    if not regex.is_available() then
        pending("libpcre2-8 not available on this machine")
        return
    end

    -- In regex mode the compiled PCRE2 pattern is the engine: it bakes in case
    -- via its compile flags and the fuzzy query argument is ignored.
    it("matches against the compiled pattern, ignoring the fuzzy query", function()
        local re = assert(regex.compile("(foo|bar)", "i"))
        assert.not_nil(do_match("BAR.lua", "ignored", re, false))
        assert.is_nil(do_match("baz.lua", "ignored", re, false))
    end)

    it("honours the case flag baked into the compiled pattern", function()
        assert.is_nil(do_match("FOO.txt", "", assert(regex.compile("foo")), false))
        assert.not_nil(do_match("FOO.txt", "", assert(regex.compile("foo", "i")), false))
    end)

    it("uses PCRE grammar (groups, alternation, quantifiers, dot)", function()
        assert.not_nil(do_match("AAAB", "", assert(regex.compile("a+b", "i")), false))
        assert.not_nil(do_match("foXbar", "", assert(regex.compile("fo.bar", "i")), false))
        assert.not_nil(do_match("v7", "", assert(regex.compile("v\\d", "i")), false))
    end)
end)

describe("regex compile (picker contract)", function()
    if not regex.is_available() then
        pending("libpcre2-8 not available on this machine")
        return
    end

    -- The picker treats a malformed pattern as "no matches" by short-circuiting
    -- on a nil compile result, rather than erroring on every file.
    it("returns nil + error for a malformed pattern", function()
        assert.is_nil((regex.compile("(foo")))
        assert.is_nil((regex.compile("a{2,1}")))
    end)
end)

describe("do_match (fuzzy)", function()
    it("matches case-insensitively then gates on case_sensitive", function()
        assert.not_nil(do_match("README.md", "rdme", false, false))
        assert.not_nil(do_match("FooBar", "foo", false, false))
        assert.is_nil(do_match("FooBar", "foo", false, true))
        assert.not_nil(do_match("FooBar", "Foo", false, true))
    end)
end)
