local keys = require("keystone.clue.keys")

--- Map an entry list to comparable {key, desc, is_group} tuples.
local function tuples(entries)
    return vim.tbl_map(function(e)
        return { e.key, e.desc, e.is_group }
    end, entries)
end

describe("clue.keys raw-byte matching", function()
    local maps

    before_each(function()
        vim.g.mapleader = " "
        -- isolate from any ambient global maps the test runner may carry
        vim.keymap.set("n", "<leader>ff", "<cmd>echo 1<cr>", { desc = "find files" })
        vim.keymap.set("n", "<leader>fg", "<cmd>echo 2<cr>", { desc = "live grep" })
        vim.keymap.set("n", "<leader>w", "<cmd>echo 3<cr>", { desc = "write" })
        vim.keymap.set("n", "gd", function() end, { desc = "goto def" })
        maps = keys.collect("n", require("keystone.clue.builtin"))
    end)

    after_each(function()
        pcall(vim.keymap.del, "n", "<leader>ff")
        pcall(vim.keymap.del, "n", "<leader>fg")
        pcall(vim.keymap.del, "n", "<leader>w")
        pcall(vim.keymap.del, "n", "gd")
    end)

    it("expands <leader> to raw bytes", function()
        assert.are.equal(" ", keys.to_raw("<leader>"))
        assert.are.equal(" w", keys.to_raw("<leader>w"))
    end)

    it("detects children and exact matches", function()
        assert.is_true(keys.has_children(maps, keys.to_raw("<leader>")))
        assert.is_true(keys.has_children(maps, keys.to_raw("<leader>f")))
        assert.is_not_nil(keys.exact(maps, keys.to_raw("<leader>w")))
        assert.is_nil(keys.exact(maps, keys.to_raw("<leader>f")))
    end)

    it("groups a multi-leaf prefix and labels leaves", function()
        assert.are.same(
            { { "f", "+2", true }, { "w", "write", false } },
            tuples(keys.clues(maps, keys.to_raw("<leader>"), {}))
        )
    end)

    it("lists individual leaves under a group", function()
        assert.are.same(
            { { "f", "find files", false }, { "g", "live grep", false } },
            tuples(keys.clues(maps, keys.to_raw("<leader>f"), {}))
        )
    end)

    it("applies a configured group label", function()
        local groups = { [table.concat(keys.tokenize(keys.to_raw("<leader>f")))] = "find" }
        local entries = keys.clues(maps, keys.to_raw("<leader>"), groups)
        assert.are.equal("+find", entries[1].desc)
    end)

    it("includes built-in clues and lets a real mapping win", function()
        local entries = keys.clues(maps, keys.to_raw("g"), {})
        local gg, gd
        for _, e in ipairs(entries) do
            if e.key == "g" then gg = e.desc end
            if e.key == "d" then gd = e.desc end
        end
        assert.are.equal("first line", gg) -- built-in
        assert.are.equal("goto def", gd) -- mapped wins over built-in
    end)

    it("decodes special keys into readable tokens", function()
        assert.are.same({ "<Space>" }, keys.tokenize(keys.to_raw("<leader>")))
        assert.are.same({ "<C-W>", "v" }, keys.tokenize(keys.to_raw("<C-w>v")))
        assert.are.same({ "<lt>", "<lt>" }, keys.tokenize(keys.to_raw("<<")))
    end)
end)

describe("clue.observer state machine", function()
    local clue = require("keystone.clue")
    local observer = require("keystone.clue.observer")

    -- `_handle_key` reads the current mode; these tests run in normal mode.
    local function press(s)
        observer._handle_key(keys.to_raw(s))
    end

    before_each(function()
        vim.g.mapleader = " "
        vim.keymap.set("n", "<leader>ff", "<cmd>echo 1<cr>", { desc = "find files" })
        vim.keymap.set("n", "<leader>fg", "<cmd>echo 2<cr>", { desc = "live grep" })
        vim.keymap.set("n", "<leader>w", "<cmd>echo 3<cr>", { desc = "write" })
        -- builtins off to isolate; the window renders synchronously
        clue.setup({ builtin_clues = false, clues = {} })
        observer.config = clue.config
        observer._build()
        observer._reset()
    end)

    after_each(function()
        observer._reset()
        clue.disable()
        for _, lhs in ipairs({ "<leader>ff", "<leader>fg", "<leader>w" }) do
            pcall(vim.keymap.del, "n", lhs)
        end
    end)

    it("does not begin on a non-trigger key", function()
        press("x")
        assert.is_false(observer._state().active)
    end)

    it("begins and shows on a trigger with children", function()
        press("<leader>")
        local s = observer._state()
        assert.is_true(s.active)
        assert.is_true(s.win) -- window opened synchronously
    end)

    it("narrows the prefix as keys are pressed", function()
        press("<leader>")
        press("f")
        local s = observer._state()
        assert.is_true(s.active)
        assert.are.equal(" f", s.raw)
    end)

    it("resolves and tears down on a complete mapping", function()
        press("<leader>")
        press("w") -- exact <leader>w, no children
        local s = observer._state()
        assert.is_false(s.active)
        assert.is_false(s.win)
    end)

    it("tears down when the sequence breaks", function()
        press("<leader>")
        press("z") -- no <leader>z mapping
        assert.is_false(observer._state().active)
    end)

    it("cancels on <Esc>", function()
        press("<leader>")
        assert.is_true(observer._state().active)
        press("<Esc>")
        assert.is_false(observer._state().active)
    end)

    it("holds 'timeout' off while pending and restores it on teardown", function()
        vim.o.timeout = true
        press("<leader>")
        assert.is_false(vim.o.timeout) -- held so Neovim waits for the next key
        press("w") -- resolves <leader>w
        assert.is_true(vim.o.timeout) -- restored
    end)
end)

describe("clue.window", function()
    local window = require("keystone.clue.window")

    it("renders a column grid with highlight spans", function()
        window.setup_hl()
        local entries = {}
        for i = 1, 6 do
            local k = string.char(96 + i)
            table.insert(entries, {
                key = k,
                desc = (i % 2 == 0) and ("+" .. i) or ("do " .. k),
                is_group = i % 2 == 0,
            })
        end
        local h = window.open(entries, " <leader> ", {
            border = "rounded",
            separator = "  ",
            width_ratio = 0.9,
            max_height_ratio = 0.4,
            title = true,
        })
        assert.is_true(vim.api.nvim_win_is_valid(h.win))
        assert.are.equal("editor", vim.api.nvim_win_get_config(h.win).relative)

        local ns = vim.api.nvim_get_namespaces()["keystone_clue"]
        local marks = vim.api.nvim_buf_get_extmarks(h.buf, ns, 0, -1, {})
        assert.are.equal(#entries * 3, #marks) -- key + separator + desc per entry

        window.close(h)
        assert.is_false(vim.api.nvim_win_is_valid(h.win))
    end)
end)
