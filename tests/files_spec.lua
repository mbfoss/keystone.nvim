local files = require("keystone.pick.pickers.files")

local escape_mode_atoms = files._escape_mode_atoms
local resolve_case      = files._resolve_case
local do_match          = files._do_match

describe("escape_mode_atoms", function()
    it("doubles the backslash on magic-mode switch atoms", function()
        assert.equals("\\\\vtest", escape_mode_atoms("\\vtest"))
        assert.equals("\\\\Vfoo", escape_mode_atoms("\\Vfoo"))
        assert.equals("\\\\mfoo", escape_mode_atoms("\\mfoo"))
        assert.equals("\\\\Mfoo", escape_mode_atoms("\\Mfoo"))
    end)

    it("doubles the backslash on case switch atoms", function()
        assert.equals("\\\\cfoo", escape_mode_atoms("\\cfoo"))
        assert.equals("\\\\Cfoo", escape_mode_atoms("\\Cfoo"))
    end)

    it("leaves other escaped atoms untouched", function()
        assert.equals("\\d\\w\\s", escape_mode_atoms("\\d\\w\\s"))
        assert.equals("\\(foo\\)", escape_mode_atoms("\\(foo\\)"))
    end)

    it("preserves an already-escaped backslash", function()
        -- `\\` is a literal backslash; the following v is not a mode atom.
        assert.equals("\\\\v", escape_mode_atoms("\\\\v"))
        assert.equals("a\\\\b", escape_mode_atoms("a\\\\b"))
    end)

    it("leaves plain text and a trailing backslash alone", function()
        assert.equals("foobar", escape_mode_atoms("foobar"))
        assert.equals("foo\\", escape_mode_atoms("foo\\"))
    end)

    it("handles several atoms in one query", function()
        assert.equals("\\\\vfoo\\\\Vbar", escape_mode_atoms("\\vfoo\\Vbar"))
    end)
end)

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
    it("is case-insensitive by default and gated by case_sensitive", function()
        assert.is_not_nil(do_match("FOO.txt", "foo", true, false))
        assert.is_nil(do_match("FOO.txt", "foo", true, true))
        assert.is_not_nil(do_match("FOO.txt", "FOO", true, true))
    end)

    it("treats a user \\v as literal, not a magic-mode switch", function()
        assert.is_not_nil(do_match("a\\vtest_b", "\\vtest", true, false))
        assert.is_nil(do_match("mytest.lua", "\\vtest", true, false))
    end)

    it("treats a user \\C as literal, not a case switch", function()
        -- The prefix's \c still governs case, so this stays insensitive: the
        -- query matches the literal text "\Cfoo", not the file "FOO".
        assert.is_nil(do_match("FOO", "\\Cfoo", true, false))
        assert.is_not_nil(do_match("x\\Cfoo", "\\Cfoo", true, false))
    end)

    it("uses very-magic grammar (groups, alternation, quantifiers)", function()
        assert.is_not_nil(do_match("BAR.lua", "(foo|bar)", true, false))
        assert.is_not_nil(do_match("AAAB", "a+b", true, false))
        assert.is_not_nil(do_match("foXbar", "fo.bar", true, false))
    end)

    it("preserves ordinary atoms and escaped backslashes", function()
        assert.is_not_nil(do_match("v7", "v\\d", true, false))
        assert.is_not_nil(do_match("a\\b", "a\\\\b", true, false))
    end)

    it("returns nil (no error) for a malformed pattern", function()
        assert.is_nil(do_match("foo", "(foo", true, false))
        assert.is_nil(do_match("FOO", "foo\\", true, false))
    end)
end)

describe("do_match (fuzzy)", function()
    it("matches case-insensitively then gates on case_sensitive", function()
        assert.is_not_nil(do_match("README.md", "rdme", false, false))
        assert.is_not_nil(do_match("FooBar", "foo", false, false))
        assert.is_nil(do_match("FooBar", "foo", false, true))
        assert.is_not_nil(do_match("FooBar", "Foo", false, true))
    end)
end)
