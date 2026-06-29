local gittool = require("keystone.gittool")

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
        assert.same({}, gittool._changed_paths(root, "HEAD"))
    end)

    it("reports modified, deleted, and untracked files (but not unchanged)", function()
        write(root .. "/mod.txt", "changed\n")
        vim.fn.delete(root .. "/gone.txt")
        write(root .. "/new.txt", "brand new\n")

        local rels = gittool._changed_paths(root, "HEAD")
        table.sort(rels)
        assert.same({ "gone.txt", "mod.txt", "new.txt" }, rels)
    end)

    it("diffs against an arbitrary rev", function()
        local first = vim.trim(vim.system(
            { "git", "rev-parse", "HEAD" }, { text = true, cwd = root }):wait().stdout)

        write(root .. "/mod.txt", "second\n")
        git(root, { "commit", "-aqm", "second" })

        -- Working tree now matches HEAD, so nothing changed against HEAD...
        assert.same({}, gittool._changed_paths(root, "HEAD"))
        -- ...but mod.txt differs from the first commit.
        assert.same({ "mod.txt" }, gittool._changed_paths(root, first))
    end)
end)
