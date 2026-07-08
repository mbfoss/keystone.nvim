local diff = require("keystone.diff")

local files_differ        = diff._files_differ
local list_files          = diff._list_files
local collect_dir_changes = diff._collect_dir_changes

--- Create a scratch directory tree from a { relpath = contents } spec and
--- return its absolute root. Registered for cleanup by the caller.
---@param spec table<string, string>
---@return string root
local function make_tree(spec)
    local root = vim.fn.tempname()
    for rel, contents in pairs(spec) do
        local full = root .. "/" .. rel
        vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
        vim.fn.writefile(vim.split(contents, "\n", { plain = true }), full)
    end
    return root
end

describe("diff._files_differ", function()
    local dir
    before_each(function()
        dir = make_tree({
            ["same_a.txt"]  = "hello\nworld",
            ["same_b.txt"]  = "hello\nworld",
            ["diff_a.txt"]  = "hello\nworld",
            ["diff_b.txt"]  = "hello\nCHANGED",
            ["short.txt"]   = "hi",
            ["long.txt"]    = "hello there",
        })
    end)
    after_each(function() vim.fn.delete(dir, "rf") end)

    it("reports identical files as equal", function()
        assert.is_false(files_differ(dir .. "/same_a.txt", dir .. "/same_b.txt"))
    end)

    it("reports files with same size but different content as differing", function()
        assert.is_true(files_differ(dir .. "/diff_a.txt", dir .. "/diff_b.txt"))
    end)

    it("reports files of different size as differing", function()
        assert.is_true(files_differ(dir .. "/short.txt", dir .. "/long.txt"))
    end)

    it("treats an unreadable path as differing", function()
        assert.is_true(files_differ(dir .. "/same_a.txt", dir .. "/does_not_exist.txt"))
    end)
end)

describe("diff._list_files", function()
    local dir
    before_each(function()
        dir = make_tree({
            ["top.txt"]         = "a",
            ["sub/nested.txt"]  = "b",
            ["sub/deep/x.txt"]  = "c",
        })
    end)
    after_each(function() vim.fn.delete(dir, "rf") end)

    it("collects regular files recursively as relative paths", function()
        local rels = list_files(dir)
        assert.is_true(rels["top.txt"])
        assert.is_true(rels["sub/nested.txt"])
        assert.is_true(rels["sub/deep/x.txt"])
    end)

    it("does not report directories as entries", function()
        local rels = list_files(dir)
        assert.is_nil(rels["sub"])
        assert.is_nil(rels["sub/deep"])
    end)
end)

describe("diff._collect_dir_changes", function()
    local left, right
    before_each(function()
        left = make_tree({
            ["same.txt"]        = "keep",
            ["mod.txt"]         = "old",
            ["only_left.txt"]   = "L",
            ["sub/gone.txt"]    = "x",
        })
        right = make_tree({
            ["same.txt"]        = "keep",
            ["mod.txt"]         = "new",
            ["only_right.txt"]  = "R",
        })
    end)
    after_each(function()
        vim.fn.delete(left, "rf")
        vim.fn.delete(right, "rf")
    end)

    --- Index the returned entries by their display path for easy assertions.
    ---@return table<string, keystone.diff.Entry>
    local function by_display()
        local out = {}
        for _, e in ipairs(collect_dir_changes(left, right)) do out[e.display] = e end
        return out
    end

    it("omits files that are identical on both sides", function()
        assert.is_nil(by_display()["same.txt"])
    end)

    it("marks files present on both sides but differing as modified", function()
        local e = by_display()["mod.txt"]
        assert.equals("M", e.status)
        assert.is_not_nil(e.left_path)
        assert.is_not_nil(e.right_path)
    end)

    it("marks left-only files as deleted (no right path)", function()
        local e = by_display()["only_left.txt"]
        assert.equals("D", e.status)
        assert.is_not_nil(e.left_path)
        assert.is_nil(e.right_path)
    end)

    it("marks right-only files as added (no left path)", function()
        local e = by_display()["only_right.txt"]
        assert.equals("A", e.status)
        assert.is_nil(e.left_path)
        assert.is_not_nil(e.right_path)
    end)

    it("recurses into subdirectories", function()
        assert.equals("D", by_display()["sub/gone.txt"].status)
    end)

    it("returns entries sorted by display path", function()
        local entries = collect_dir_changes(left, right)
        local prev
        for _, e in ipairs(entries) do
            if prev then assert.is_true(prev < e.display) end
            prev = e.display
        end
    end)
end)

describe("diff.diff_dirs (integration)", function()
    local left, right
    before_each(function()
        left = make_tree({ ["a.txt"] = "one", ["b.txt"] = "two" })
        right = make_tree({ ["a.txt"] = "one", ["b.txt"] = "CHANGED" })
    end)
    after_each(function()
        pcall(function() require("keystone.diff").clear_session() end)
        vim.fn.delete(left, "rf")
        vim.fn.delete(right, "rf")
    end)

    it("opens a side-by-side layout with a location list of changes", function()
        vim.cmd("only")
        diff.diff_dirs(left, right)

        local win = vim.api.nvim_get_current_win()
        local info = vim.fn.getloclist(win, { items = 1, title = 1 })
        assert.equals("Keystone Diff", info.title)
        assert.equals(1, #info.items)          -- only b.txt differs
        assert.equals("M", info.items[1].text)
        assert.is_true(#vim.api.nvim_tabpage_list_wins(0) >= 3) -- left + right + loclist
    end)

    it("reports no differences for identical trees", function()
        vim.cmd("only")
        local before = #vim.api.nvim_tabpage_list_wins(0)
        diff.diff_dirs(left, left)
        assert.equals(before, #vim.api.nvim_tabpage_list_wins(0)) -- no layout opened
    end)
end)
