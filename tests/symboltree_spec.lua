local kinds = require("keystone.symboltree.kinds")

describe("symboltree.kinds", function()
    it("maps every LSP SymbolKind code 1..26", function()
        for code = 1, 26 do
            assert.not_nil(kinds.kinds[code])
            assert.is_truthy(kinds.get(code).name)
        end
    end)

    it("falls back for an unknown kind", function()
        assert.equals("Unknown", kinds.get(99).name)
        assert.equals("Unknown", kinds.get(nil).name)
    end)
end)

describe("symboltree.setup config", function()
    local symboltree = require("keystone.symboltree")

    after_each(function()
        symboltree.setup({})
    end)

    it("collapses functions, methods and objects by default", function()
        symboltree.setup({})
        assert.are.same({ "Function", "Method", "Object" }, symboltree.config.collapse_kinds)
    end)

    it("replaces list options outright instead of merging them by index", function()
        symboltree.setup({ collapse_kinds = { "Class" }, exclude_kinds = { "Variable" } })
        assert.are.same({ "Class" }, symboltree.config.collapse_kinds)
        assert.are.same({ "Variable" }, symboltree.config.exclude_kinds)
    end)

    it("keeps a user list independent of the config table", function()
        local user = { "Class" }
        symboltree.setup({ collapse_kinds = user })
        table.insert(user, "Struct")
        assert.are.same({ "Class" }, symboltree.config.collapse_kinds)
    end)

    it("restores the default list when setup is called again without it", function()
        symboltree.setup({ collapse_kinds = { "Class" } })
        symboltree.setup({})
        assert.are.same({ "Function", "Method", "Object" }, symboltree.config.collapse_kinds)
    end)
end)
