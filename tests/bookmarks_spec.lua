local core = require("keystone.bookmarks.core")

describe("bookmarks.decode_line", function()
    local decode = core.decode_line

    it("parses a bare location", function()
        local e = decode("foo.lua:42")
        assert.not_nil(e)
        assert.equals(42, e.lnum)
        assert.is_nil(e.label)
        assert.is_truthy(e.file:match("foo%.lua$"))
    end)

    it("parses a location with a label", function()
        local e = decode("foo.lua:42 -- my note")
        assert.equals(42, e.lnum)
        assert.equals("my note", e.label)
    end)

    it("keeps a ' -- ' that appears inside the label", function()
        local e = decode("foo.lua:42 -- a -- b")
        assert.equals(42, e.lnum)
        assert.equals("a -- b", e.label)
    end)

    it("keeps a bare '--' inside the file path", function()
        local e = decode("foo--bar.lua:10")
        assert.not_nil(e)
        assert.equals(10, e.lnum)
        assert.is_truthy(e.file:match("foo%-%-bar%.lua$"))
    end)

    it("handles a '--' path together with a label", function()
        local e = decode("foo--bar.lua:10 -- note")
        assert.equals(10, e.lnum)
        assert.equals("note", e.label)
        assert.is_truthy(e.file:match("foo%-%-bar%.lua$"))
    end)

    it("keeps colons that precede the line number in the path", function()
        local e = decode("a:b:10")
        assert.not_nil(e)
        assert.equals(10, e.lnum)
        assert.is_truthy(e.file:match("a:b$"))
    end)

    it("trims surrounding whitespace", function()
        local e = decode("  foo.lua:7   ")
        assert.equals(7, e.lnum)
    end)

    it("returns nil for blank or malformed lines", function()
        assert.is_nil(decode(""))
        assert.is_nil(decode("   "))
        assert.is_nil(decode("not a bookmark"))
        assert.is_nil(decode("foo.lua:notanumber"))
    end)
end)

describe("bookmarks.sync_from_buffer", function()
    before_each(function()
        core.init(vim.tbl_extend("force", core.default_config(), {
            persist_path = vim.fn.tempname(),
        }))
        core.mark_group.remove_extmarks()
    end)

    after_each(function()
        core.mark_group.remove_extmarks()
    end)

    ---@param lines string[]
    ---@return integer bufnr
    local function make_list(lines)
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        return bufnr
    end

    it("adds bookmarks from valid lines", function()
        core.sync_from_buffer(make_list({ "a.lua:1", "b.lua:2 -- note" }))
        assert.equals(2, #core.read_entries(false))
    end)

    it("drops malformed lines and flags them in place", function()
        local bufnr = make_list({ "a.lua:1", "garbage", "b.lua:2" })
        core.sync_from_buffer(bufnr)
        assert.equals(2, #core.read_entries(false))

        local marks = vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, {})
        assert.equals(1, #marks)
        assert.equals(1, marks[1][2]) -- 0-based row of "garbage"
    end)

    it("ignores blank lines without flagging them", function()
        local bufnr = make_list({ "a.lua:1", "", "   " })
        core.sync_from_buffer(bufnr)
        assert.equals(1, #core.read_entries(false))
        assert.equals(0, #vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, {}))
    end)

    it("removes bookmarks whose lines were deleted", function()
        core.sync_from_buffer(make_list({ "a.lua:1", "b.lua:2" }))
        assert.equals(2, #core.read_entries(false))

        core.sync_from_buffer(make_list({ "a.lua:1" }))
        assert.equals(1, #core.read_entries(false))
    end)

    it("keeps duplicate lines as separate bookmarks", function()
        core.sync_from_buffer(make_list({ "a.lua:1", "a.lua:1" }))
        assert.equals(2, #core.read_entries(false))
    end)
end)
