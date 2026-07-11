local files = require("keystone.pick.pickers.files")

local resolve_case = files._resolve_case
local do_match     = files._do_match

describe("resolve_case", function()
    it("honors explicit on/off", function()
        assert.is_true(resolve_case("on", "foo", false))
        assert.is_false(resolve_case("off", "FOO", false))
    end)

    it("smart-cases on uppercase for literal text", function()
        assert.is_false(resolve_case("smart", "foo", false))
        assert.is_true(resolve_case("smart", "Foo", false))
        assert.is_false(resolve_case(nil, "foo", false))
    end)

    it("degrades to insensitive for regex unless forced on", function()
        assert.is_false(resolve_case(nil, "Foo", true))
        assert.is_false(resolve_case("smart", "FOO", true))
        assert.is_true(resolve_case("on", "foo", true))
    end)
end)

describe("regex filter (integration)", function()
    if vim.fn.executable("rg") == 0 then
        pending("ripgrep (rg) not available on this machine")
        return
    end

    -- Regex mode streams candidate filenames through a single ripgrep over
    -- stdin and maps matches back to their files. Drive the picker's finder
    -- end to end over a temp directory.
    local function run(dir, query, flags)
        local spec = files.spec({ cwd = dir })
        local result, done = {}, false
        spec.finder(query, flags, { list_width = 80, list_height = 40 }, function(items)
            if items == nil then done = true else result = items end
        end, nil)
        assert.is_true(vim.wait(5000, function() return done end, 20), "finder timed out")
        return result
    end

    local function basenames(items)
        local names = {}
        for _, it in ipairs(items) do
            if it.data and it.data.filepath then
                names[#names + 1] = vim.fn.fnamemodify(it.data.filepath, ":t")
            end
        end
        table.sort(names)
        return names
    end

    it("keeps only filenames matching the ripgrep regex", function()
        local dir = vim.fn.resolve(vim.fn.tempname())
        vim.fn.mkdir(dir, "p")
        vim.fn.writefile({}, dir .. "/alpha.lua")
        vim.fn.writefile({}, dir .. "/beta.txt")
        vim.fn.writefile({}, dir .. "/gamma.lua")

        assert.are.same({ "alpha.lua", "gamma.lua" }, basenames(run(dir, "\\.lua$", { regex = true })))
    end)

    it("highlights the matched portion of the filename", function()
        local dir = vim.fn.resolve(vim.fn.tempname())
        vim.fn.mkdir(dir, "p")
        vim.fn.writefile({}, dir .. "/alpha.lua")

        local result = run(dir, "\\.lua$", { regex = true })
        assert.are.equal(1, #result)
        -- the ".lua" suffix should be its own highlighted chunk (fuzzy uses "Todo")
        local found = false
        for _, ch in ipairs(result[1].label_chunks) do
            if ch[1] == ".lua" and ch[2] == "Todo" then found = true end
        end
        assert.is_true(found, "expected a highlighted '.lua' chunk")
    end)

    it("surfaces a bad pattern as an inline error row", function()
        local dir = vim.fn.resolve(vim.fn.tempname())
        vim.fn.mkdir(dir, "p")
        vim.fn.writefile({}, dir .. "/a.txt")

        local result = run(dir, "(unterminated", { regex = true })
        assert.are.equal(1, #result)
        assert.is_nil(result[1].data.filepath) -- error rows carry no filepath
    end)
end)

describe("do_match (fuzzy)", function()
    it("matches case-insensitively then gates on case_sensitive", function()
        assert.not_nil(do_match("README.md", "rdme", false))
        assert.not_nil(do_match("FooBar", "foo", false))
        assert.is_nil(do_match("FooBar", "foo", true))
        assert.not_nil(do_match("FooBar", "Foo", true))
    end)
end)
