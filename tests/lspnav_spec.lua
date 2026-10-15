local lspnav = require("keystone.lspnav")
local symbols = require("keystone.util.lspsymbols")

-- LSP SymbolKind codes, named at the call sites for readability.
local CLASS, METHOD, CONSTRUCTOR, FUNCTION = 5, 6, 9, 12
local FUNCTION_KINDS = { METHOD, CONSTRUCTOR, FUNCTION }
local TYPE_KINDS = { 2, 3, CLASS, 10, 11, 23 }

---@param sl integer
---@param sc integer
---@param el integer
---@param ec integer
local function range(sl, sc, el, ec)
    return { start = { line = sl, character = sc }, ["end"] = { line = el, character = ec } }
end

--- A `DocumentSymbol` spanning `lnum`..`end_lnum`, 0-based as on the wire, whose
--- selection starts where its name does.
local function sym(name, kind, lnum, col, end_lnum, children)
    local r = range(lnum, col, end_lnum or lnum, col)
    return { name = name, kind = kind, range = r, selectionRange = r, children = children }
end

--- A flat `SymbolInformation[]`, the other shape a server may reply with.
local function info(name, kind, sl, sc, el, ec)
    return { name = name, kind = kind, location = { uri = "file:///x.lua", range = range(sl, sc, el, ec) } }
end

--- Normalized and flattened, as `lspnav.jump` feeds `lspnav.pick`.
local function flat(reply)
    return lspnav.flatten(symbols.normalize(reply))
end

--- The name `lspnav.pick` picks, or nil at that end of the buffer.
---@param reply table[]
---@param line integer 1-based cursor line
---@param character integer LSP character offset of the cursor
local function pick(reply, line, character, kinds, direction, count)
    local target = lspnav.pick(flat(reply), { line = line, character = character }, kinds, direction, count)
    return target and target.name or nil
end

--- Two top-level functions, one of them holding a nested one, and a class
--- holding a method.
---@return table[]
local function doc()
    return {
        sym("first", FUNCTION, 0, 0, 9),
        sym("second", FUNCTION, 3, 0, 6, {
            sym("nested", FUNCTION, 4, 4, 5),
        }),
        sym("Klass", CLASS, 11, 0, 20, {
            sym("method", METHOD, 12, 4, 15),
        }),
        sym("last", FUNCTION, 22, 0, 25),
    }
end

describe("lspnav.flatten", function()
    it("returns children in depth-first position order", function()
        local names = {}
        for _, symbol in ipairs(flat(doc())) do
            names[#names + 1] = symbol.name
        end
        assert.same({ "first", "second", "nested", "Klass", "method", "last" }, names)
    end)

    it("flattens a flat SymbolInformation reply to the same order", function()
        local names = {}
        for _, symbol in ipairs(flat({
            info("outer", FUNCTION, 0, 0, 9, 0),
            info("inner", FUNCTION, 2, 4, 4, 4),
            info("after", FUNCTION, 12, 0, 15, 0),
        })) do
            names[#names + 1] = symbol.name
        end
        assert.same({ "outer", "inner", "after" }, names)
    end)
end)

describe("lspnav.lspnav.pick", function()
    it("stops on the next function below the cursor", function()
        assert.equals("second", pick(doc(), 2, 0, FUNCTION_KINDS, "next"))
    end)

    it("skips a class when the function kinds are asked for", function()
        -- The class is not a function, so the next function is the method in it.
        assert.equals("second", pick(doc(), 1, 0, FUNCTION_KINDS, "next"))
        assert.equals("method", pick(doc(), 12, 0, FUNCTION_KINDS, "next"))
    end)

    it("stops on the next class with the type kinds", function()
        assert.equals("Klass", pick(doc(), 1, 0, TYPE_KINDS, "next"))
        assert.is_nil(pick(doc(), 13, 0, TYPE_KINDS, "next"))
    end)

    it("reaches a nested function", function()
        assert.equals("nested", pick(doc(), 4, 0, FUNCTION_KINDS, "next"))
    end)

    it("returns to the enclosing function from inside it", function()
        assert.equals("second", pick(doc(), 5, 0, FUNCTION_KINDS, "prev"))
        assert.equals("nested", pick(doc(), 6, 0, FUNCTION_KINDS, "prev"))
    end)

    it("counts the symbol under the cursor as neither direction", function()
        -- On a definition, both directions move past it, so a repeat press
        -- escapes the function instead of sticking to it.
        assert.equals("first", pick(doc(), 4, 0, FUNCTION_KINDS, "prev"))
        assert.equals("nested", pick(doc(), 4, 0, FUNCTION_KINDS, "next"))
    end)

    it("returns nil at the ends of the buffer", function()
        assert.is_nil(pick(doc(), 23, 0, FUNCTION_KINDS, "next"))
        assert.is_nil(pick(doc(), 1, 0, FUNCTION_KINDS, "prev"))
    end)

    it("tells apart two definitions on one line", function()
        local inline = {
            sym("a", FUNCTION, 0, 0, 0),
            sym("b", FUNCTION, 0, 20, 0),
        }
        assert.equals("b", pick(inline, 1, 0, FUNCTION_KINDS, "next"))
        assert.is_nil(pick(inline, 1, 0, FUNCTION_KINDS, "prev"))

        -- Column decides, not line: a line-only comparison sees nothing on
        -- either side of a cursor that is between the two.
        assert.equals("b", pick(inline, 1, 10, FUNCTION_KINDS, "next"))
        assert.equals("a", pick(inline, 1, 10, FUNCTION_KINDS, "prev"))

        assert.is_nil(pick(inline, 1, 20, FUNCTION_KINDS, "next"))
    end)

    it("moves by the count, stopping at the end", function()
        assert.equals("nested", pick(doc(), 1, 0, FUNCTION_KINDS, "next", 2))
        assert.equals("last", pick(doc(), 1, 0, FUNCTION_KINDS, "next", 99))
        assert.equals("nested", pick(doc(), 23, 0, FUNCTION_KINDS, "prev", 2))
        assert.equals("first", pick(doc(), 23, 0, FUNCTION_KINDS, "prev", 99))
    end)

    it("agrees between the two reply shapes", function()
        local tree = {
            sym("outer", FUNCTION, 0, 0, 9),
            sym("inner", FUNCTION, 3, 4, 5),
        }
        local flat_reply = {
            info("outer", FUNCTION, 0, 0, 9, 0),
            info("inner", FUNCTION, 3, 4, 5, 4),
        }
        for _, direction in ipairs({ "next", "prev" }) do
            for _, line in ipairs({ 1, 4, 9 }) do
                assert.equals(
                    pick(tree, line, 0, FUNCTION_KINDS, direction),
                    pick(flat_reply, line, 0, FUNCTION_KINDS, direction)
                )
            end
        end
    end)
end)

describe("lspnav offsets", function()
    -- Byte, utf-8, utf-16 and utf-32 offsets just past each character.
    local ascii = "ab"
    local accented = "a\u{e9} b"
    local astral = "a\240\159\152\128b"

    it("leaves a plain ASCII line alone", function()
        for _, encoding in ipairs({ "utf-8", "utf-16", "utf-32" }) do
            assert.equals(1, lspnav.char_offset(ascii, 1, encoding))
            assert.equals(1, lspnav.byte_col(ascii, 1, encoding))
        end
    end)

    it("converts a two-byte character", function()
        assert.equals(3, lspnav.char_offset(accented, 3, "utf-8"))
        assert.equals(2, lspnav.char_offset(accented, 3, "utf-16"))
        assert.equals(2, lspnav.char_offset(accented, 3, "utf-32"))
    end)

    it("counts an astral character as two utf-16 units", function()
        assert.equals(5, lspnav.char_offset(astral, 5, "utf-8"))
        assert.equals(3, lspnav.char_offset(astral, 5, "utf-16"))
        assert.equals(2, lspnav.char_offset(astral, 5, "utf-32"))
    end)

    it("converts back to the same byte offset", function()
        assert.equals(5, lspnav.byte_col(astral, 3, "utf-16"))
        assert.equals(5, lspnav.byte_col(astral, 2, "utf-32"))
        assert.equals(3, lspnav.byte_col(accented, 2, "utf-16"))
    end)

    it("clamps an offset past the end of the line", function()
        assert.equals(2, lspnav.char_offset(ascii, 99, "utf-16"))
        assert.equals(2, lspnav.byte_col(ascii, 99, "utf-16"))
        assert.equals(0, lspnav.byte_col(ascii, -1, "utf-16"))
    end)

    it("falls back to utf-16 for a missing or unknown encoding", function()
        assert.equals("utf-16", lspnav.encoding(nil))
        assert.equals("utf-16", lspnav.encoding("latin-1"))
        assert.equals("utf-8", lspnav.encoding("utf-8"))
    end)
end)

describe("lspnav config", function()

    after_each(function()
        -- Back to defaults, so one case cannot leak kinds into the next.
        lspnav.setup({})
    end)

    it("stops on functions and types by default", function()
        local defaults = lspnav.get_default_config()
        assert.same({ 6, 9, 12 }, defaults.function_kinds)
        assert.same({ 2, 3, 5, 10, 11, 23 }, defaults.type_kinds)
    end)

    it("replaces a kind list wholesale, leaving the other alone", function()
        lspnav.setup({ type_kinds = { 5 } })
        assert.same({ 5 }, lspnav.config.type_kinds)
        assert.same({ 6, 9, 12 }, lspnav.config.function_kinds)
    end)

    it("drives the actions from the configured kinds", function()
        lspnav.setup({ function_kinds = {} })
        -- No kinds to stop on, and nothing attached to ask for symbols, so this
        -- is a no-op rather than an error.
        lspnav.next_function()
        lspnav.next_type()
    end)

    it("reports itself as set up", function()
        assert.is_true(lspnav.is_setup())
        assert.same({ 6, 9, 12 }, lspnav.config.function_kinds)
    end)
end)
