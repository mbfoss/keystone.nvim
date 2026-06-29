local gittool = require("keystone.gittool")
local difftool = require("keystone.gittool.diff")
local diffthis = require("keystone.gittool.diffthis")

--- Run a git command in `cwd`, asserting success. Used only by the fixtures.
---@param cwd  string
---@param args string[]
local function git(cwd, args)
    local cmd = { "git" }
    vim.list_extend(cmd, args)
    local res = vim.system(cmd, { text = true, cwd = cwd }):wait()
    assert.equal(0, res.code, "git " .. table.concat(args, " ") .. ": " .. (res.stderr or ""))
end

--- Write `data` to `path`, creating parent directories.
---@param path string
---@param data string
local function write(path, data)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local fd = assert(io.open(path, "wb"))
    fd:write(data)
    fd:close()
end

describe("gittool setup", function()
    it("registers the GitTool command", function()
        gittool.setup()
        assert.is_not_nil(vim.api.nvim_get_commands({})["GitTool"])
    end)
end)

describe("gittool _changed_paths", function()
    local root

    before_each(function()
        root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        git(root, { "init", "-q" })
        git(root, { "config", "user.email", "test@example.com" })
        git(root, { "config", "user.name", "Test" })

        write(root .. "/kept.txt", "unchanged\n")
        write(root .. "/mod.txt", "original\n")
        write(root .. "/gone.txt", "to be deleted\n")
        git(root, { "add", "-A" })
        git(root, { "commit", "-q", "-m", "initial" })
    end)

    after_each(function()
        vim.fn.delete(root, "rf")
    end)

    it("returns nothing on a clean tree", function()
        assert.same({}, difftool.changed_paths(root, "HEAD"))
    end)

    it("reports modified, deleted, and untracked files (but not unchanged)", function()
        write(root .. "/mod.txt", "changed\n")
        vim.fn.delete(root .. "/gone.txt")
        write(root .. "/new.txt", "brand new\n")

        local rels = difftool.changed_paths(root, "HEAD")
        table.sort(rels)
        assert.same({ "gone.txt", "mod.txt", "new.txt" }, rels)
    end)

    it("diffs against an arbitrary rev", function()
        local first = vim.trim(vim.system(
            { "git", "rev-parse", "HEAD" }, { text = true, cwd = root }):wait().stdout)

        write(root .. "/mod.txt", "second\n")
        git(root, { "commit", "-aqm", "second" })

        -- Working tree now matches HEAD, so nothing changed against HEAD...
        assert.same({}, difftool.changed_paths(root, "HEAD"))
        -- ...but mod.txt differs from the first commit.
        assert.same({ "mod.txt" }, difftool.changed_paths(root, first))
    end)
end)

describe("gittool _changed_paths_between", function()
    local root, first

    before_each(function()
        root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        git(root, { "init", "-q" })
        git(root, { "config", "user.email", "test@example.com" })
        git(root, { "config", "user.name", "Test" })

        write(root .. "/kept.txt", "unchanged\n")
        write(root .. "/mod.txt", "original\n")
        git(root, { "add", "-A" })
        git(root, { "commit", "-q", "-m", "initial" })
        first = vim.trim(vim.system(
            { "git", "rev-parse", "HEAD" }, { text = true, cwd = root }):wait().stdout)
    end)

    after_each(function()
        vim.fn.delete(root, "rf")
    end)

    it("reports only paths differing between two revisions, ignoring the working tree", function()
        write(root .. "/mod.txt", "second\n")
        write(root .. "/added.txt", "new in second\n")
        git(root, { "add", "-A" })
        git(root, { "commit", "-q", "-m", "second" })

        -- An unrelated, uncommitted working-tree change must not leak in.
        write(root .. "/kept.txt", "dirty\n")

        local rels = difftool.changed_paths_between(root, { rev = first }, { rev = "HEAD" })
        assert.same({ "added.txt", "mod.txt" }, rels)
    end)

    it("default diff reports the working tree against the index (unstaged + untracked)", function()
        -- Staged-only change: the working tree matches the index, so it must
        -- NOT appear in a bare working-tree-vs-index diff.
        write(root .. "/mod.txt", "staged change\n")
        git(root, { "add", "mod.txt" })

        -- An unstaged edit and an untracked file both differ from the index.
        write(root .. "/kept.txt", "unstaged edit\n")
        write(root .. "/untracked.txt", "untracked\n")

        local rels = difftool.changed_paths_between(root, { index = true }, { worktree = true })
        assert.same({ "kept.txt", "untracked.txt" }, rels)
    end)

    it("staged diff reports the index against HEAD, excluding unstaged and untracked", function()
        write(root .. "/mod.txt", "staged change\n")
        write(root .. "/staged_new.txt", "staged add\n")
        git(root, { "add", "mod.txt", "staged_new.txt" })

        -- An unstaged edit and an untracked file must not appear in a staged diff.
        write(root .. "/kept.txt", "unstaged edit\n")
        write(root .. "/untracked.txt", "untracked\n")

        local rels = difftool.changed_paths_between(root, { rev = "HEAD" }, { index = true })
        assert.same({ "mod.txt", "staged_new.txt" }, rels)
    end)
end)

--- The buffers whose name carries the `gittool://` scheme (the diffthis scratch
--- side). Used to assert the scratch buffer is gone once the diff ends.
---@return integer[]
local function gittool_bufs()
    local out = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b)
            and vim.api.nvim_buf_get_name(b):find("gittool://", 1, true) then
            out[#out + 1] = b
        end
    end
    return out
end

---@param win integer
---@return boolean
local function win_diff(win)
    return vim.api.nvim_get_option_value("diff", { win = win })
end

describe("gittool diffthis", function()
    local root, file

    before_each(function()
        root = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        -- fs_realpath needs the dir to exist; resolve symlinks (macOS /tmp ->
        -- /private/tmp) so the buffer path matches git's canonical root.
        root = vim.uv.fs_realpath(root) or root
        git(root, { "init", "-q" })
        git(root, { "config", "user.email", "test@example.com" })
        git(root, { "config", "user.name", "Test" })

        file = root .. "/mod.txt"
        write(file, "original\n")
        git(root, { "add", "-A" })
        git(root, { "commit", "-q", "-m", "initial" })

        -- An unstaged edit, then open the file as the live buffer.
        write(file, "changed\n")
        vim.cmd.edit(file)
    end)

    after_each(function()
        vim.cmd("silent! only")
        vim.cmd("silent! %bwipeout!")
        vim.wait(50) -- drain any pending scheduled teardown
        vim.fn.delete(root, "rf")
    end)

    it("opens a gittool:// scratch buffer with both sides in diff mode", function()
        local live_buf = vim.api.nvim_get_current_buf()
        diffthis.diffthis({})

        local scratch = gittool_bufs()
        assert.equal(1, #scratch)

        local live_win = vim.fn.win_findbuf(live_buf)[1]
        local base_win = vim.fn.win_findbuf(scratch[1])[1]
        assert.is_not_nil(live_win)
        assert.is_not_nil(base_win)
        assert.is_true(win_diff(live_win))
        assert.is_true(win_diff(base_win))
    end)

    it("closing the live window drops the scratch buffer and restores the file", function()
        local live_buf = vim.api.nvim_get_current_buf()
        diffthis.diffthis({})
        local base_buf = gittool_bufs()[1]
        local live_win = vim.fn.win_findbuf(live_buf)[1]
        local base_win = vim.fn.win_findbuf(base_buf)[1]

        vim.api.nvim_win_close(live_win, true)
        assert.is_true(vim.wait(500, function() return #gittool_bufs() == 0 end))

        -- The scratch buffer's window is sent back to the live file, diff off.
        assert.equal(live_buf, vim.api.nvim_win_get_buf(base_win))
        assert.is_false(win_diff(base_win))
    end)

    it("closing the scratch window wipes it and clears diff on the live window", function()
        local live_buf = vim.api.nvim_get_current_buf()
        diffthis.diffthis({})
        local base_buf = gittool_bufs()[1]
        local live_win = vim.fn.win_findbuf(live_buf)[1]
        local base_win = vim.fn.win_findbuf(base_buf)[1]

        vim.api.nvim_win_close(base_win, true)
        assert.is_true(vim.wait(500, function()
            return #gittool_bufs() == 0 and not win_diff(live_win)
        end))
        assert.is_false(win_diff(live_win))
    end)
end)
