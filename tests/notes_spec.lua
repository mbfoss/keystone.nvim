local core = require("keystone.notes.core")

describe("notes.decode_line", function()
    local decode = core.decode_line

    it("parses a note with no reference", function()
        local n = decode("remember to refactor the parser")
        assert.not_nil(n)
        assert.equals("remember to refactor the parser", n.label)
        assert.is_nil(n.file)
        assert.is_nil(n.lnum)
    end)

    it("parses an @ reference with a line number", function()
        local n = decode("off-by-one in @foo.lua:42")
        assert.equals(42, n.lnum)
        assert.is_truthy(n.file:match("foo%.lua$"))
    end)

    it("parses an @ reference with no line number", function()
        local n = decode("the whole thing needs a rewrite @foo.lua")
        assert.is_nil(n.lnum)
        assert.is_truthy(n.file:match("foo%.lua$"))
    end)

    it("finds the reference at the start, middle or end of the text", function()
        for _, line in ipairs({
            "@foo.lua:42 is where the bug is",
            "the bug is in @foo.lua:42 near the top",
            "the bug is in @foo.lua:42",
        }) do
            local n = decode(line)
            assert.equals(42, n.lnum, line)
            assert.is_truthy(n.file:match("foo%.lua$"), line)
        end
    end)

    it("keeps the reference inside the note text", function()
        local n = decode("look at @foo.lua:42 tomorrow")
        assert.is_truthy(n.label:match("^look at @"))
        assert.is_truthy(n.label:match(":42 tomorrow$"))
        assert.equals("look at ", n.prefix)
        assert.equals(" tomorrow", n.suffix)
    end)

    it("ignores an @ that does not start a token", function()
        local n = decode("ask bob@example.com about it")
        assert.is_nil(n.file)
        assert.equals("ask bob@example.com about it", n.label)
    end)

    it("takes the first reference when there are several", function()
        local n = decode("compare @first.lua:1 against @second.lua:2")
        assert.equals(1, n.lnum)
        assert.is_truthy(n.file:match("first%.lua$"))
        assert.is_truthy(n.suffix:match("@second%.lua:2$"))
    end)

    it("keeps colons that precede the line number in the path", function()
        local n = decode("note @a:b:10")
        assert.equals(10, n.lnum)
        assert.is_truthy(n.file:match("a:b$"))
    end)

    it("re-renders the reference in canonical form", function()
        local n = decode("note @foo.lua:7")
        assert.equals(core.render(n.prefix, n.file, n.lnum, n.suffix), n.label)
    end)

    it("trims surrounding whitespace", function()
        local n = decode("   a note   ")
        assert.equals("a note", n.label)
    end)

    it("returns nil for blank lines", function()
        assert.is_nil(decode(""))
        assert.is_nil(decode("   "))
    end)
end)

describe("notes.find_ref", function()
    it("reports the span of the reference", function()
        local start, stop, path, lnum = core.find_ref("see @foo.lua:9 now")
        assert.equals(5, start)
        assert.equals(14, stop)
        assert.equals("foo.lua", path)
        assert.equals(9, lnum)
    end)

    it("returns nil when there is no reference", function()
        assert.is_nil(core.find_ref("nothing to see here"))
        assert.is_nil(core.find_ref("mail bob@example.com"))
    end)
end)

describe("notes.refs", function()
    it("collects every reference on the line", function()
        local refs = core.refs("compare @first.lua:1 with @second.lua:2 and @third.lua")
        assert.equals(3, #refs)
        assert.is_truthy(refs[1].file:match("first%.lua$"))
        assert.equals(1, refs[1].lnum)
        assert.is_truthy(refs[2].file:match("second%.lua$"))
        assert.equals(2, refs[2].lnum)
        assert.is_truthy(refs[3].file:match("third%.lua$"))
        assert.is_nil(refs[3].lnum)
    end)

    it("skips an @ that does not start a token", function()
        local refs = core.refs("mail bob@example.com about @real.lua:3")
        assert.equals(1, #refs)
        assert.is_truthy(refs[1].file:match("real%.lua$"))
    end)
end)

describe("notes.ref_at", function()
    -- Columns are 1-based:  "see @a.lua:1 and @b.lua:2"
    --                        123456789...
    local line = "see @a.lua:1 and @b.lua:2"

    it("picks the reference the column falls inside", function()
        for _, col in ipairs({ 5, 8, 12 }) do
            local ref = core.ref_at(line, col)
            assert.not_nil(ref, "col " .. col)
            assert.is_truthy(ref.file:match("a%.lua$"), "col " .. col)
        end

        for _, col in ipairs({ 18, 21, 25 }) do
            local ref = core.ref_at(line, col)
            assert.not_nil(ref, "col " .. col)
            assert.is_truthy(ref.file:match("b%.lua$"), "col " .. col)
        end
    end)

    it("returns nil between and outside the references", function()
        assert.is_nil(core.ref_at(line, 1))  -- 's' of "see"
        assert.is_nil(core.ref_at(line, 4))  -- the space before the first
        assert.is_nil(core.ref_at(line, 14)) -- 'a' of "and"
        assert.is_nil(core.ref_at(line, 99)) -- past the end
    end)

    it("returns nil on a line with no reference", function()
        assert.is_nil(core.ref_at("just some prose", 3))
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
        core.sync_from_buffer(make_list({ "plain note", "anchored @b.lua:2" }))
        assert.equals(2, #core.read_notes())
    end)

    it("ignores blank lines", function()
        core.sync_from_buffer(make_list({ "a note", "", "   " }))
        assert.equals(1, #core.read_notes())
    end)

    it("anchors only the notes naming a line", function()
        core.sync_from_buffer(make_list({
            "plain note",
            "file only @b.lua",
            "anchored @b.lua:2",
        }))
        local anchored = vim.tbl_filter(function(n) return n.lnum ~= nil end, core.read_notes())
        assert.equals(3, #core.read_notes())
        assert.equals(1, #anchored)
    end)

    it("keeps the file of a reference with no line", function()
        core.sync_from_buffer(make_list({ "file only @b.lua" }))
        local n = core.read_notes()[1]
        assert.is_truthy(n.file:match("b%.lua$"))
        assert.is_nil(n.lnum)
    end)

    it("removes notes whose lines were deleted", function()
        core.sync_from_buffer(make_list({ "one", "two @b.lua:2" }))
        assert.equals(2, #core.read_notes())

        core.sync_from_buffer(make_list({ "one" }))
        local notes = core.read_notes()
        assert.equals(1, #notes)
        assert.equals("one", notes[1].label)
    end)

    it("keeps duplicate lines as separate notes", function()
        core.sync_from_buffer(make_list({ "same", "same" }))
        assert.equals(2, #core.read_notes())
    end)

    it("keeps the id of an unchanged note across a sync", function()
        core.sync_from_buffer(make_list({ "keep me @a.lua:1" }))
        local id = core.read_notes()[1].id

        core.sync_from_buffer(make_list({ "keep me @a.lua:1", "and a new one" }))
        local kept = vim.tbl_filter(function(n) return n.label:match("^keep me") end,
            core.read_notes())
        assert.equals(1, #kept)
        assert.equals(id, kept[1].id)
    end)
end)

describe("notes.add_at", function()
    before_each(function()
        core.init(vim.tbl_extend("force", core.default_config(), {
            persist_path = vim.fn.tempname(),
        }))
        core.remove_all()
    end)

    after_each(function()
        core.remove_all()
    end)

    it("appends a reference to the text", function()
        core.add_at("check this", vim.fn.tempname() .. "/a.lua", 12)
        local n = core.read_notes()[1]
        assert.equals("check this ", n.prefix)
        assert.equals(12, n.lnum)
        assert.is_truthy(n.label:match("^check this @"))
        assert.is_truthy(n.label:match(":12$"))
    end)

    it("adds no reference without a file", function()
        core.add_at("just a thought")
        local n = core.read_notes()[1]
        assert.equals("just a thought", n.label)
        assert.is_nil(n.file)
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
        core.add_at("zebra", vim.fn.tempname() .. "/a.lua", 1)
        core.add_at("apple")
        core.add_at("mango", vim.fn.tempname() .. "/z.lua", 9)

        local first = vim.tbl_map(function(n) return n.label:match("^%S+") end,
            core.sorted_notes())
        assert.same({ "apple", "mango", "zebra" }, first)
    end)
end)
