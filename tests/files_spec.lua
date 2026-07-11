local files = require("keystone.pick.pickers.files")

local resolve_case = files._resolve_case
local do_match     = files._do_match

describe("resolve_case", function()
    it("honors explicit on/off", function()
        assert.is_true(resolve_case("on", "foo"))
        assert.is_false(resolve_case("off", "FOO"))
    end)

    it("smart-cases on uppercase for literal text", function()
        assert.is_false(resolve_case("smart", "foo"))
        assert.is_true(resolve_case("smart", "Foo"))
        assert.is_false(resolve_case(nil, "foo"))
    end)
end)

describe("do_match (fuzzy)", function()
    it("matches case-insensitively then gates on case_sensitive", function()
        assert.not_nil(do_match("README.md", "rdme", false))
        assert.not_nil(do_match("FooBar", "foo", false))
        assert.is_nil(do_match("FooBar", "foo", true))
        assert.not_nil(do_match("FooBar", "Foo", true))
    end)
end)
