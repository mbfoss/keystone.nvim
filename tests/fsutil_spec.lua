local fsutil = require("keystone.tk.fsutil")
local filetreefs = require("keystone.filetree.fs")

describe("copy_destination", function()
    local tmp

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
    end)

    after_each(function()
        vim.fn.delete(tmp, "rf")
    end)

    local function touch(name)
        local path = vim.fs.joinpath(tmp, name)
        assert(fsutil.create_file(path))
        return path
    end

    it("inserts ' copy' before the extension", function()
        local path = touch("foo.txt")
        assert.equals(vim.fs.joinpath(tmp, "foo copy.txt"), filetreefs.copy_destination(path, false))
    end)

    it("numbers subsequent copies", function()
        local path = touch("foo.txt")
        touch("foo copy.txt")
        touch("foo copy 2.txt")
        assert.equals(vim.fs.joinpath(tmp, "foo copy 3.txt"), filetreefs.copy_destination(path, false))
    end)

    it("appends to extension-less and dot files", function()
        assert.equals(vim.fs.joinpath(tmp, "Makefile copy"),
            filetreefs.copy_destination(touch("Makefile"), false))
        assert.equals(vim.fs.joinpath(tmp, ".gitignore copy"),
            filetreefs.copy_destination(touch(".gitignore"), false))
    end)

    it("treats directory names as having no extension", function()
        local dir = vim.fs.joinpath(tmp, "my.dir")
        vim.fn.mkdir(dir)
        assert.equals(vim.fs.joinpath(tmp, "my.dir copy"), filetreefs.copy_destination(dir, true))
    end)

    it("skips existing directories when numbering", function()
        local dir = vim.fs.joinpath(tmp, "sub")
        vim.fn.mkdir(dir)
        vim.fn.mkdir(vim.fs.joinpath(tmp, "sub copy"))
        assert.equals(vim.fs.joinpath(tmp, "sub copy 2"), filetreefs.copy_destination(dir, true))
    end)
end)
