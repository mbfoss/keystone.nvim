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
        -- The notes buffer is module state: leaving one behind would make the next
        -- test read its lines instead of the file.
        local bufnr = core.live_bufnr()
        if bufnr then vim.api.nvim_buf_delete(bufnr, { force = true }) end
        vim.fn.delete(path)
    end)

    ---@return string[]
    local function lines()
        return vim.fn.readfile(path)
    end

    --- A temporary directory holding `sub/a.lua`, spelled the way `getcwd()` will
    --- report it: on macOS the temp root is a symlink, and the stored absolute paths
    --- have to match what a `:cd` into the directory yields.
    ---@return string
    local function _tempdir()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir .. "/sub", "p")
        vim.fn.writefile({ "x" }, dir .. "/sub/a.lua")
        return vim.fs.normalize(vim.fn.resolve(dir))
    end

    it("returns no notes when the file does not exist", function()
        assert.same({}, core.read_notes())
    end)

    it("appends a note per call, in order", function()
        core.append_line("first")
        core.append_line("second")
        assert.same({ "first", "second" }, lines())
    end)

    it("puts the reference ahead of the text", function()
        core.add_at("check this", vim.fn.tempname() .. "/a.lua", 12)
        local n = core.read_notes()[1]
        assert.equals(12, n.lnum)
        assert.is_truthy(n.label:match("^@"))
        assert.is_truthy(n.label:match(":12 check this$"))
    end)

    it("stores the absolute path even for a file under the cwd", function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir .. "/sub", "p")
        vim.fn.writefile({ "x" }, dir .. "/sub/a.lua")

        local cwd = vim.fn.getcwd()
        vim.cmd.cd(dir)
        core.add_at("in the project", dir .. "/sub/a.lua", 7)
        vim.cmd.cd(cwd)

        assert.same({ "@" .. vim.fs.normalize(dir) .. "/sub/a.lua:7 in the project" }, lines())
    end)

    it("stores an absolute path for a file outside the cwd too", function()
        core.add_at("elsewhere", "/etc/hosts")
        assert.same({ "@/etc/hosts elsewhere" }, lines())
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

    it("fills the notes buffer from the file, without editing it", function()
        vim.fn.writefile({ "existing" }, path)
        local bufnr = core.get_buffer()

        assert.same({ "existing" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
        assert.equals("nofile", vim.bo[bufnr].buftype)
        assert.is_false(vim.bo[bufnr].swapfile)
    end)

    it("shows stored paths relative to the cwd, storing them absolute again", function()
        local dir = _tempdir()
        local abs = dir .. "/sub/a.lua"
        vim.fn.writefile({ "@" .. abs .. ":7 in the project", "@/etc/hosts outside" }, path)

        local cwd = vim.fn.getcwd()
        vim.cmd.cd(dir)
        local bufnr = core.get_buffer()
        assert.same({ "@sub/a.lua:7 in the project", "@/etc/hosts outside" },
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

        -- The reference still resolves to the file it named.
        assert.equals(abs, core.read_notes()[1].file)

        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "@sub/a.lua typed relative" })
        core.save_buffer(bufnr)
        vim.cmd.cd(cwd)

        assert.same({
            "@" .. abs .. ":7 in the project",
            "@/etc/hosts outside",
            "@" .. abs .. " typed relative",
        }, lines())
    end)

    it("re-renders the shown paths when the cwd changes", function()
        local dir = _tempdir()
        local abs = dir .. "/sub/a.lua"
        vim.fn.writefile({ "@" .. abs .. ":7 a note" }, path)

        local cwd = vim.fn.getcwd()
        local bufnr = core.get_buffer() -- filled from outside the directory
        assert.same({ "@" .. abs .. ":7 a note" },
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

        -- What the DirChangedPre/DirChanged pair does around a `:cd`.
        local function cd(to)
            core.snapshot_lines(bufnr)
            vim.cmd.cd(to)
            core.refresh_display(bufnr)
        end

        cd(dir)
        assert.same({ "@sub/a.lua:7 a note" },
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

        cd(dir .. "/sub")
        assert.same({ "@a.lua:7 a note" },
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

        cd(cwd)
        assert.same({ "@" .. abs .. ":7 a note" },
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

        -- Re-rendering is not an edit: with nothing else changed there is nothing to
        -- write, so the file is left exactly as it was.
        vim.fn.delete(path)
        core.save_buffer(bufnr)
        assert.equals(0, vim.fn.filereadable(path))
    end)

    it("leaves an @token that names no file alone", function()
        vim.fn.writefile({ "see @param foo -- not a path" }, path)
        local bufnr = core.get_buffer()
        assert.same({ "see @param foo -- not a path" },
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "and @nosuchfile.lua:3" })
        core.save_buffer(bufnr)
        assert.same({ "see @param foo -- not a path", "and @nosuchfile.lua:3" }, lines())
    end)

    -- What another Neovim instance sharing the notes file does behind this one's back.
    ---@param new_lines string[]
    local function other_instance_writes(new_lines)
        vim.fn.writefile(new_lines, path)
    end

    it("keeps both instances' notes when the file changed underneath", function()
        vim.fn.writefile({ "shared one", "shared two" }, path)
        local bufnr = core.get_buffer()

        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "mine" })
        other_instance_writes({ "shared one", "shared two", "theirs" })
        core.save_buffer(bufnr)

        assert.same({ "shared one", "shared two", "theirs", "mine" }, lines())
        -- The merged result is what the buffer shows, too.
        assert.same({ "shared one", "shared two", "theirs", "mine" },
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)

    it("applies a deletion to the other instance's version", function()
        vim.fn.writefile({ "keep", "drop me" }, path)
        local bufnr = core.get_buffer()

        vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, {}) -- delete "drop me"
        other_instance_writes({ "keep", "drop me", "theirs" })
        core.save_buffer(bufnr)

        assert.same({ "keep", "theirs" }, lines())
    end)

    it("takes in the other instance's notes with nothing of its own to write", function()
        vim.fn.writefile({ "shared" }, path)
        local bufnr = core.get_buffer()

        other_instance_writes({ "shared", "theirs" })
        core.save_buffer(bufnr) -- not dirty: syncs instead of writing

        assert.same({ "shared", "theirs" },
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
        assert.same({ "shared", "theirs" }, lines())
    end)

    it("syncs without dropping unsaved edits, and writes both on the next save", function()
        vim.fn.writefile({ "shared" }, path)
        local bufnr = core.get_buffer()

        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "mine, unsaved" })
        other_instance_writes({ "shared", "theirs" })
        core.sync_buffer(bufnr)

        assert.same({ "shared", "theirs", "mine, unsaved" },
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
        assert.same({ "shared", "theirs" }, lines()) -- sync writes nothing

        core.save_buffer(bufnr)
        assert.same({ "shared", "theirs", "mine, unsaved" }, lines())
    end)

    it("keeps its notes when the file goes missing rather than treating it as emptied", function()
        vim.fn.writefile({ "one", "two" }, path)
        local bufnr = core.get_buffer()

        vim.fn.delete(path)
        core.sync_buffer(bufnr)
        assert.same({ "one", "two" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

        -- An empty file, on the other hand, is another instance deleting every note.
        other_instance_writes({})
        core.sync_buffer(bufnr)
        assert.same({ "" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)

    it("does not leave its temporary file behind", function()
        local bufnr = core.get_buffer()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a note" })
        core.save_buffer(bufnr)

        assert.same({ "a note" }, lines())
        assert.same({}, vim.fn.glob(path .. ".tmp*", false, true))
    end)

    it("appends through a live notes buffer, saving it", function()
        vim.fn.writefile({ "existing" }, path)
        local bufnr = core.get_buffer()

        core.append_line("in buffer")
        assert.same({ "existing", "in buffer" },
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
        assert.same({ "existing", "in buffer" }, lines())
    end)

    it("reads notes from the buffer while it holds unwritten edits", function()
        vim.fn.writefile({ "on disk" }, path)
        local bufnr = core.get_buffer()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "edited, not saved" })

        assert.equals("edited, not saved", core.read_notes()[1].label)
        assert.same({ "on disk" }, lines())
    end)

    it("saves the buffer only when it has changes", function()
        vim.fn.writefile({ "existing" }, path)
        local bufnr = core.get_buffer()

        -- Untouched since it was filled, so the file is left alone entirely -- deleted
        -- underneath, it stays deleted.
        vim.fn.delete(path)
        core.save_buffer(bufnr)
        assert.equals(0, vim.fn.filereadable(path))

        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "edited" })
        core.save_buffer(bufnr)
        assert.same({ "existing", "edited" }, lines())
    end)

    it("writes the file even when it does not exist yet", function()
        local bufnr = core.get_buffer()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a note" })
        core.save_buffer()
        assert.same({ "a note" }, lines())
    end)
end)

