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
        assert.equals("look at @foo.lua:42 tomorrow", n.label)
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
        assert.is_truthy(n.label:match("@second%.lua:2$"))
    end)

    it("keeps colons that precede the line number in the path", function()
        local n = decode("note @a:b:10")
        assert.equals(10, n.lnum)
        assert.is_truthy(n.file:match("a:b$"))
    end)

    it("stores the line verbatim, reference and all", function()
        local n = decode("see @param and @foo.lua:7")
        assert.equals("see @param and @foo.lua:7", n.label)
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

describe("notes store", function()
    local path

    before_each(function()
        path = vim.fn.tempname()
        core.init(vim.tbl_extend("force", core.default_config(), { persist_path = path }))
    end)

    after_each(function()
        vim.fn.delete(path)
    end)

    ---@return string[]
    local function lines()
        return vim.fn.readfile(path)
    end

    it("returns no notes when the file does not exist", function()
        assert.same({}, core.read_notes())
    end)

    it("appends a note per call, in order", function()
        core.append_line("first")
        core.append_line("second")
        assert.same({ "first", "second" }, lines())
    end)

    it("appends a reference to the text", function()
        core.add_at("check this", vim.fn.tempname() .. "/a.lua", 12)
        local n = core.read_notes()[1]
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

    it("does not join onto a file with no trailing newline", function()
        vim.fn.writefile({ "existing" }, path, "b") -- no trailing newline
        core.append_line("appended")
        assert.same({ "existing", "appended" }, lines())
    end)

    it("reads the notes back, skipping blank lines", function()
        vim.fn.writefile({ "one", "", "   ", "two @b.lua:2" }, path)
        local notes = core.read_notes()
        assert.equals(2, #notes)
        assert.equals("one", notes[1].label)
        assert.equals(2, notes[2].lnum)
    end)

    it("stores pasted text verbatim, @tokens included", function()
        core.append_line("see @param foo -- not a path rewrite")
        assert.same({ "see @param foo -- not a path rewrite" }, lines())
    end)

    it("appends through a loaded buffer editing the file, saving it", function()
        vim.fn.writefile({ "existing" }, path)
        local bufnr = vim.fn.bufadd(path)
        vim.fn.bufload(bufnr)

        core.append_line("in buffer")
        assert.same({ "existing", "in buffer" },
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
        assert.same({ "existing", "in buffer" }, lines())
        assert.is_false(vim.bo[bufnr].modified)

        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("saves the buffer only when it has changes", function()
        vim.fn.writefile({ "existing" }, path)
        local bufnr = vim.fn.bufadd(path)
        vim.fn.bufload(bufnr)

        core.save_buffer(bufnr) -- unmodified: nothing to write
        assert.same({ "existing" }, lines())

        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "edited" })
        core.save_buffer(bufnr)
        assert.same({ "existing", "edited" }, lines())

        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
end)

