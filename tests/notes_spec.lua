local core = require("keystone.notes.core")

describe("notes.decode_line", function()
    local decode = core.decode_line

    it("parses a bare note", function()
        local n = decode("remember to refactor the parser")
        assert.not_nil(n)
        assert.equals("remember to refactor the parser", n.label)
        assert.is_nil(n.file)
        assert.is_nil(n.lnum)
    end)

    it("parses a note with a location", function()
        local n = decode("off-by-one here -- foo.lua:42")
        assert.equals("off-by-one here", n.label)
        assert.equals(42, n.lnum)
        assert.is_truthy(n.file:match("foo%.lua$"))
    end)

    it("anchors on the last ' -- ', keeping earlier ones in the note", function()
        local n = decode("a -- b -- foo.lua:42")
        assert.equals("a -- b", n.label)
        assert.equals(42, n.lnum)
    end)

    it("keeps a bare '--' inside the file path", function()
        local n = decode("note -- foo--bar.lua:10")
        assert.equals("note", n.label)
        assert.equals(10, n.lnum)
        assert.is_truthy(n.file:match("foo%-%-bar%.lua$"))
    end)

    it("keeps colons that precede the line number in the path", function()
        local n = decode("note -- a:b:10")
        assert.equals("note", n.label)
        assert.equals(10, n.lnum)
        assert.is_truthy(n.file:match("a:b$"))
    end)

    it("treats a tail that is not a location as part of the note", function()
        local n = decode("see -- the other thing")
        assert.equals("see -- the other thing", n.label)
        assert.is_nil(n.file)

        n = decode("check -- foo.lua:notanumber")
        assert.equals("check -- foo.lua:notanumber", n.label)
        assert.is_nil(n.file)
    end)

    it("keeps a location-shaped note with no text as plain text", function()
        local n = decode("foo.lua:42")
        assert.equals("foo.lua:42", n.label)
        assert.is_nil(n.file)
    end)

    it("trims surrounding whitespace", function()
        local n = decode("  a note   ")
        assert.equals("a note", n.label)

        n = decode("  a note -- foo.lua:7   ")
        assert.equals("a note", n.label)
        assert.equals(7, n.lnum)
    end)

    it("returns nil for blank lines", function()
        assert.is_nil(decode(""))
        assert.is_nil(decode("   "))
    end)
end)

describe("notes.sync_from_buffer", function()
    before_each(function()
        core.init(vim.tbl_extend("force", core.default_config(), {
            persist_path = vim.fn.tempname(),
        }))
        core.remove_all()
    end)

    after_each(function()
        core.remove_all()
    end)

    ---@param lines string[]
    ---@return integer bufnr
    local function make_list(lines)
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        return bufnr
    end

    it("adds notes from non-blank lines", function()
        core.sync_from_buffer(make_list({ "plain note", "anchored -- b.lua:2" }))
        assert.equals(2, #core.read_notes(false))
    end)

    it("ignores blank lines", function()
        core.sync_from_buffer(make_list({ "a note", "", "   " }))
        assert.equals(1, #core.read_notes(false))
    end)

    it("only signs the anchored notes", function()
        core.sync_from_buffer(make_list({ "plain note", "anchored -- b.lua:2" }))
        assert.equals(1, #core.mark_group.get_extmarks(false))
    end)

    it("removes notes whose lines were deleted", function()
        core.sync_from_buffer(make_list({ "one", "two -- b.lua:2" }))
        assert.equals(2, #core.read_notes(false))

        core.sync_from_buffer(make_list({ "one" }))
        local notes = core.read_notes(false)
        assert.equals(1, #notes)
        assert.equals("one", notes[1].label)
    end)

    it("keeps duplicate lines as separate notes", function()
        core.sync_from_buffer(make_list({ "same", "same" }))
        assert.equals(2, #core.read_notes(false))
    end)

    it("keeps the id of an unchanged note across a sync", function()
        core.sync_from_buffer(make_list({ "keep me -- a.lua:1" }))
        local id = core.read_notes(false)[1].id

        core.sync_from_buffer(make_list({ "keep me -- a.lua:1", "and a new one" }))
        local kept = vim.tbl_filter(function(n) return n.label == "keep me" end, core.read_notes(false))
        assert.equals(1, #kept)
        assert.equals(id, kept[1].id)
    end)
end)

describe("notes.sorted_notes", function()
    before_each(function()
        core.init(vim.tbl_extend("force", core.default_config(), {
            persist_path = vim.fn.tempname(),
        }))
        core.remove_all()
    end)

    after_each(function()
        core.remove_all()
    end)

    it("orders by the note text, not the location", function()
        core.add("zebra", vim.fn.tempname() .. "/a.lua", 1)
        core.add("apple")
        core.add("mango", vim.fn.tempname() .. "/z.lua", 9)

        local labels = vim.tbl_map(function(n) return n.label end, core.sorted_notes(false))
        assert.same({ "apple", "mango", "zebra" }, labels)
    end)
end)
