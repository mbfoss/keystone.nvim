local pickertools = require("keystone.pick.base.pickertools")

local match = pickertools.match_label

describe("match_label case-insensitive (default)", function()
    it("matches regardless of case", function()
        assert.is_not_nil(match("Foobar", "foo"))
        assert.is_not_nil(match("foobar", "FOO"))
        assert.is_not_nil(match("README.md", "rdme"))
    end)

    it("returns nil when characters are absent", function()
        assert.is_nil(match("foobar", "xyz"))
    end)

    it("matches an empty query", function()
        assert.is_not_nil(match("foobar", ""))
    end)
end)

describe("match_label case-sensitive", function()
    it("accepts an exact-case match", function()
        assert.is_not_nil(match("Foobar", "Foo", true))
        assert.is_not_nil(match("FooBar", "FB", true))
    end)

    it("rejects a wrong-case match the fuzzy matcher would otherwise accept", function()
        assert.is_not_nil(match("Foobar", "foo")) -- sanity: matches case-insensitively
        assert.is_nil(match("Foobar", "foo", true))
        assert.is_nil(match("foobar", "FOO", true))
    end)

    it("matches non-contiguous subsequences case-sensitively", function()
        assert.is_not_nil(match("FooBarBaz", "FBB", true))
        assert.is_nil(match("FooBarBaz", "fbb", true))
    end)
end)
