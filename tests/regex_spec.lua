local regex = require("keystone.util.regex")

-- The FFI wrapper needs a loadable libpcre2-8. Skip gracefully when absent so
-- the suite still runs on machines without PCRE2 installed.
local available = regex.is_available()

describe("regex (pcre2 ffi)", function()
	if not available then
		pending("libpcre2-8 not available on this machine")
		return
	end

	describe("compile", function()
		it("returns nil + error for an invalid pattern", function()
			local re, err = regex.compile("(")
			assert.is_nil(re)
			assert.is_string(err)
		end)

		it("reports the number of capture groups", function()
			assert.equals(0, regex.compile("\\d+"):count_captures())
			assert.equals(2, regex.compile("(\\w+)=(\\d+)"):count_captures())
		end)

		it("resolves named groups", function()
			local re = assert(regex.compile("(?<y>\\d{4})-(?<m>\\d{2})"))
			assert.equals(1, re:group_index("y"))
			assert.equals(2, re:group_index("m"))
			assert.is_nil((re:group_index("nope")))
		end)
	end)

	describe("test", function()
		it("detects a match anywhere in the subject", function()
			assert.is_true(regex.test("hello world", "wor"))
			assert.is_false(regex.test("hello", "xyz"))
		end)

		it("is case-sensitive by default and caseless with 'i'", function()
			assert.is_false(regex.test("HELLO", "hello"))
			assert.is_true(regex.test("HELLO", "hello", "i"))
		end)
	end)

	describe("find", function()
		it("returns 1-based inclusive offsets and captures", function()
			local s, e, caps = regex.find("foo=42;", "(\\w+)=(\\d+)")
			assert.equals(1, s)
			assert.equals(6, e)
			assert.same({ "foo", "42" }, caps)
		end)

		it("honours a 1-based init offset", function()
			assert.equals(3, regex.compile("o"):find("foo", 3))
		end)

		it("returns nil on no match", function()
			assert.is_nil(regex.find("abc", "\\d"))
		end)
	end)

	describe("match", function()
		it("returns captures when the pattern has groups", function()
			local k, v = regex.match("name: claude", "(\\w+):\\s*(\\w+)")
			assert.equals("name", k)
			assert.equals("claude", v)
		end)

		it("returns the whole match when there are no groups", function()
			assert.equals("123", regex.match("abc123", "\\d+"))
		end)

		it("leaves a nil hole for an unmatched optional group", function()
			local a, b = regex.match("x", "(x)(y)?")
			assert.equals("x", a)
			assert.is_nil(b)
		end)
	end)

	describe("gmatch", function()
		it("iterates non-overlapping matches", function()
			local out = {}
			for n in regex.gmatch("1 22 333", "\\d+") do
				out[#out + 1] = n
			end
			assert.same({ "1", "22", "333" }, out)
		end)

		it("yields captures per step", function()
			local out = {}
			for a, b in regex.gmatch("a1b2", "(\\w)(\\d)") do
				out[#out + 1] = a .. b
			end
			assert.same({ "a1", "b2" }, out)
		end)
	end)

	describe("gsub", function()
		it("expands %n templates", function()
			local out, n = regex.gsub("2026-06-28", "(\\d+)-(\\d+)-(\\d+)", "%3/%2/%1")
			assert.equals("28/06/2026", out)
			assert.equals(1, n)
		end)

		it("uses a replacement function over the captures", function()
			local out = regex.gsub("hi there", "\\w+", function(w)
				return w:upper()
			end)
			assert.equals("HI THERE", out)
		end)

		it("keeps the original match when the function returns nil", function()
			local out = regex.gsub("a b c", "\\w", function()
				return nil
			end)
			assert.equals("a b c", out)
		end)

		it("terminates on empty matches and respects the limit", function()
			assert.equals("-a-b-c-", (regex.gsub("abc", "x*", "-")))
			local out, n = regex.compile("\\w"):gsub("abcd", "X", 2)
			assert.equals("XXcd", out)
			assert.equals(2, n)
		end)
	end)

	describe("unicode", function()
		it("treats a multibyte char as one with the 'u' flag", function()
			assert.equals("c", regex.match("café", ".", "u"))
		end)
	end)
end)
