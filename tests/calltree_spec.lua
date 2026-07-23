local calls = require("keystone.calltree.calls")

---@param sl integer
---@param sc integer
---@param el integer
---@param ec integer
local function range(sl, sc, el, ec)
    return { start = { line = sl, character = sc }, ["end"] = { line = el, character = ec } }
end

---@param name string
---@param uri string
---@param r table
local function item(name, uri, r)
    return { name = name, kind = 12, uri = uri, range = r, selectionRange = range(r.start.line, 9, r.start.line, 12) }
end

describe("calltree.calls.normalize_item", function()
    it("converts CallHierarchyItem positions to 1-based lines", function()
        local out = calls.normalize_item(item("foo", "file:///a.lua", range(0, 0, 4, 3)), 7)
        assert.not_nil(out)
        assert.equals("foo", out.name)
        assert.equals(1, out.lnum)
        assert.equals(5, out.end_lnum)
        assert.equals(7, out.client_id)
        assert.equals(0, out.call_count)
    end)

    it("takes the cursor position from selectionRange, not range", function()
        local out = calls.normalize_item(item("foo", "file:///a.lua", range(0, 0, 4, 3)), 1)
        assert.equals(9, out.col)
    end)

    it("falls back to range when selectionRange is absent", function()
        local out = calls.normalize_item(
            { name = "foo", kind = 12, uri = "file:///a.lua", range = range(2, 4, 6, 0) }, 1)
        assert.equals(3, out.lnum)
        assert.equals(4, out.col)
    end)

    it("drops entries with no usable range or uri", function()
        assert.is_nil(calls.normalize_item({ name = "no_range", kind = 12, uri = "file:///a.lua" }, 1))
        assert.is_nil(calls.normalize_item({ name = "no_uri", kind = 12, range = range(0, 0, 1, 0) }, 1))
        assert.is_nil(calls.normalize_item(nil, 1))
    end)
end)

describe("calltree.calls.normalize_calls", function()
    local incoming = {
        {
            from = item("caller_b", "file:///b.lua", range(10, 0, 20, 0)),
            fromRanges = { range(15, 4, 15, 12), range(12, 4, 12, 12) },
        },
        {
            from = item("caller_a", "file:///a.lua", range(1, 0, 5, 0)),
            fromRanges = { range(3, 2, 3, 10) },
        },
    }

    it("reads the target from `from` for incoming calls", function()
        local out = calls.normalize_calls(incoming, "incoming", "file:///root.lua", 1)
        assert.equals(2, #out)
        assert.equals("caller_a", out[1].name)
        assert.equals("caller_b", out[2].name)
    end)

    it("puts incoming call sites in the caller's own document", function()
        local out = calls.normalize_calls(incoming, "incoming", "file:///root.lua", 1)
        assert.equals("file:///a.lua", out[1].call_uri)
        assert.equals(4, out[1].call_lnum)
    end)

    it("puts outgoing call sites in the document asked about", function()
        local out = calls.normalize_calls({
            { to = item("callee", "file:///c.lua", range(30, 0, 40, 0)), fromRanges = { range(3, 2, 3, 8) } },
        }, "outgoing", "file:///root.lua", 1)
        assert.equals(1, #out)
        assert.equals("callee", out[1].name)
        assert.equals("file:///c.lua", out[1].uri)
        assert.equals(31, out[1].lnum)
        assert.equals("file:///root.lua", out[1].call_uri)
        assert.equals(4, out[1].call_lnum)
    end)

    it("points at the earliest call site and counts them all", function()
        local out = calls.normalize_calls(incoming, "incoming", "file:///root.lua", 1)
        local b = out[2]
        assert.equals("caller_b", b.name)
        assert.equals(13, b.call_lnum) -- line 12 (0-based), listed second
        assert.equals(2, b.call_count)
    end)

    it("sorts by document then position", function()
        local out = calls.normalize_calls({
            { from = item("z", "file:///b.lua", range(1, 0, 2, 0)), fromRanges = {} },
            { from = item("y", "file:///a.lua", range(9, 0, 9, 5)), fromRanges = {} },
            { from = item("x", "file:///a.lua", range(2, 0, 3, 0)), fromRanges = {} },
        }, "incoming", "file:///root.lua", 1)
        assert.equals("x", out[1].name)
        assert.equals("y", out[2].name)
        assert.equals("z", out[3].name)
    end)

    it("tolerates a missing or empty fromRanges", function()
        local out = calls.normalize_calls({
            { from = item("plain", "file:///a.lua", range(1, 0, 2, 0)) },
        }, "incoming", "file:///root.lua", 1)
        assert.equals(1, #out)
        assert.is_nil(out[1].call_lnum)
        assert.equals(0, out[1].call_count)
    end)

    it("skips entries whose target is unusable", function()
        local out = calls.normalize_calls({
            { from = { name = "broken", kind = 12 }, fromRanges = {} },
            { from = item("ok", "file:///a.lua", range(1, 0, 2, 0)), fromRanges = {} },
        }, "incoming", "file:///root.lua", 1)
        assert.equals(1, #out)
        assert.equals("ok", out[1].name)
    end)

    it("returns an empty list for nil or empty input", function()
        assert.equals(0, #calls.normalize_calls(nil, "incoming", "file:///root.lua", 1))
        assert.equals(0, #calls.normalize_calls({}, "outgoing", "file:///root.lua", 1))
    end)
end)

describe("calltree.calls.identity", function()
    it("distinguishes symbols by document and position", function()
        local a = calls.normalize_item(item("foo", "file:///a.lua", range(0, 0, 4, 0)), 1)
        local b = calls.normalize_item(item("foo", "file:///b.lua", range(0, 0, 4, 0)), 1)
        local c = calls.normalize_item(item("foo", "file:///a.lua", range(9, 0, 12, 0)), 1)
        assert.not_equals(calls.identity(a), calls.identity(b))
        assert.not_equals(calls.identity(a), calls.identity(c))
    end)

    it("matches the same symbol reached twice", function()
        local a = calls.normalize_item(item("foo", "file:///a.lua", range(0, 0, 4, 0)), 1)
        local again = calls.normalize_item(item("foo", "file:///a.lua", range(0, 0, 4, 0)), 2)
        assert.equals(calls.identity(a), calls.identity(again))
    end)
end)
