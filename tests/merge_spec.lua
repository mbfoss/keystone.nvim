local merge = require("keystone.merge")

--- Write `contents` (a "\n"-joined string) to a fresh temp file and return its
--- path.
---@param contents string
---@return string path
local function tmpfile(contents)
    local path = vim.fn.tempname()
    vim.fn.writefile(vim.split(contents, "\n", { plain = true }), path)
    return path
end

describe("merge.merge3 (integration)", function()
    local base, localf, remote, output
    before_each(function()
        base   = tmpfile("line1\nbase\nline3")
        localf = tmpfile("line1\nLOCAL\nline3")
        remote = tmpfile("line1\nREMOTE\nline3")
        -- The invoking tool (e.g. git) writes MERGED with conflict markers
        -- before launching us; simulate that here.
        output = tmpfile("line1\n<<<<<<< LOCAL\nLOCAL\n=======\nREMOTE\n>>>>>>> REMOTE\nline3")
    end)
    after_each(function()
        pcall(function() require("keystone.merge").clear_session() end)
        for _, p in ipairs({ base, localf, remote, output }) do vim.fn.delete(p) end
    end)

    it("opens a four-window layout, all in diff mode", function()
        vim.cmd("only")
        merge.merge3(localf, base, remote, output)

        local wins = vim.api.nvim_tabpage_list_wins(0)
        assert.equals(4, #wins)
        for _, w in ipairs(wins) do
            assert.is_true(vim.api.nvim_win_call(w, function() return vim.wo.diff end))
        end
    end)

    it("points the MERGED window at the output path, showing it as-is", function()
        vim.cmd("only")
        merge.merge3(localf, base, remote, output)

        local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
        assert.equals(vim.fn.resolve(vim.fn.fnamemodify(output, ":p")),
            vim.fn.resolve(vim.api.nvim_buf_get_name(buf)))
        -- The conflict markers the invoking tool wrote are shown untouched;
        -- merge3 does not re-run any merge of its own.
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        assert.is_truthy(text:find("<<<<<<<", 1, true))
        assert.is_truthy(text:find(">>>>>>>", 1, true))
    end)

    it("defaults the output to the LOCAL path when none is given", function()
        vim.cmd("only")
        merge.merge3(localf, base, remote)

        local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
        assert.equals(vim.fn.resolve(vim.fn.fnamemodify(localf, ":p")),
            vim.fn.resolve(vim.api.nvim_buf_get_name(buf)))
    end)

    it("runs only one merge at a time, replacing the previous session", function()
        vim.cmd("only")
        merge.merge3(localf, base, remote, output)
        assert.equals(4, #vim.api.nvim_tabpage_list_wins(0))
        -- A second merge must tear the first down, not stack another layout.
        merge.merge3(localf, base, remote, output)
        assert.equals(4, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it("gives the three top windows equal width", function()
        vim.o.columns = 120
        vim.cmd("only")
        merge.merge3(localf, base, remote, output)

        local widths = {}
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local width = vim.api.nvim_win_get_width(w)
            if width < vim.o.columns then widths[#widths + 1] = width end -- skip full-width MERGED
        end
        table.sort(widths)
        assert.equals(3, #widths)
        assert.is_true(widths[3] - widths[1] <= 1) -- equal up to an odd column
    end)

    it("installs buffer-local diffget mappings in the MERGED window", function()
        vim.g.maplocalleader = ","
        vim.cmd("only")
        merge.merge3(localf, base, remote, output)

        local buf = vim.api.nvim_get_current_buf()
        local seen = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
            if m.desc and m.desc:match("^Merge:") then seen[m.lhs] = true end
        end
        assert.is_true(seen[",1"])
        assert.is_true(seen[",2"])
        assert.is_true(seen[",3"])
    end)
end)
