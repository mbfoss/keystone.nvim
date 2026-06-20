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

describe("clue.engine decision", function()
    local engine = require("keystone.clue.engine")
    local maps

    local function raw(s)
        return keys.to_raw(s)
    end

    before_each(function()
        vim.g.mapleader = " "
        vim.keymap.set("n", "<leader>ff", "<cmd>echo 1<cr>", { desc = "find files" })
        vim.keymap.set("n", "<leader>fg", "<cmd>echo 2<cr>", { desc = "live grep" })
        vim.keymap.set("n", "<leader>w", "<cmd>echo 3<cr>", { desc = "write" })
        maps = keys.collect("n", {})
    end)

    after_each(function()
        for _, lhs in ipairs({ "<leader>ff", "<leader>fg", "<leader>w" }) do
            pcall(vim.keymap.del, "n", lhs)
        end
    end)

    it("keeps querying while more keys may follow", function()
        assert.are.equal("continue", engine._decide(maps, raw("<leader>"), raw("f")))
    end)

    it("executes on a unique target (no continuation)", function()
        assert.are.equal("exec", engine._decide(maps, raw("<leader>f"), raw("f")))
        assert.are.equal("exec", engine._decide(maps, raw("<leader>"), raw("w")))
    end)

    it("executes on a broken sequence so Neovim still handles the keys", function()
        assert.are.equal("exec", engine._decide(maps, raw("<leader>"), raw("z")))
    end)

    it("cancels on <Esc> / <C-c> / interrupt", function()
        assert.are.equal("cancel", engine._decide(maps, raw("<leader>"), "\27"))
        assert.are.equal("cancel", engine._decide(maps, raw("<leader>"), "\3"))
        assert.are.equal("cancel", engine._decide(maps, raw("<leader>"), ""))
    end)

    it("accepts the current prefix on <CR> and pops on <BS>", function()
        assert.are.equal("exec", engine._decide(maps, raw("<leader>f"), "\r"))
        assert.are.equal("pop", engine._decide(maps, raw("<leader>f"), keys.to_raw("<BS>")))
    end)
end)

describe("clue.engine integration", function()
    -- The `getcharstr` loop can't be driven synchronously, so exercise the real
    -- engine in a child Neovim: pre-queue keys with `nvim_input` (which feeds
    -- `getcharstr`), let the sequence re-feed, and check the mappings ran.
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

    it("executes mapped sequences via re-feed (counts, buffer-local, builtins)", function()
        local out = vim.fn.tempname()
        local script = vim.fn.tempname() .. ".lua"
        vim.fn.writefile(vim.split(string.format(
            [[
vim.opt.rtp:append(%q)
vim.g.mapleader = " "
local OUT = %q
vim.fn.writefile({}, OUT)
local function log(s) vim.fn.writefile({ s }, OUT, "a") end
vim.keymap.set("n", "<leader>ff", function() log("FF:" .. vim.v.count) end, { desc = "ff" })
vim.keymap.set("n", "gd", function() log("GD") end, { buffer = 0, desc = "gd" })
require("keystone.clue").setup({ builtin_clues = false })
vim.defer_fn(function() vim.api.nvim_input(" ff") end, 30)
vim.defer_fn(function() vim.api.nvim_input("2 ff") end, 130)
vim.defer_fn(function() vim.api.nvim_input("gd") end, 230)
vim.defer_fn(function() vim.cmd("qa!") end, 380)
]],
            root,
            out
        ), "\n"), script)

        vim.fn.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-c", "luafile " .. script })

        assert.are.same({ "FF:0", "FF:2", "GD" }, vim.fn.readfile(out))
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
