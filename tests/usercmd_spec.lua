local usercmd = require("keystone.util.usercmd")

describe("usercmd.escape_arg", function()
    it("escapes whitespace and backslash only", function()
        assert.equals("a\\ b", usercmd.escape_arg("a b"))
        assert.equals("a\\\tb", usercmd.escape_arg("a\tb"))
        assert.equals("a\\\\b", usercmd.escape_arg("a\\b"))
        -- Characters that are only special to Ex filenames, not to <f-args>,
        -- must be left alone: escaping them would keep the backslash verbatim.
        assert.equals("a%b#c|d\"e", usercmd.escape_arg("a%b#c|d\"e"))
    end)

    it("round-trips through <f-args> splitting", function()
        vim.api.nvim_create_user_command("UsercmdSpecEcho", function() end, { nargs = "*" })
        for _, name in ipairs({ "a b", "a\\b", "a\tb", "a b\\c d", "a%b" }) do
            local parsed = vim.api.nvim_parse_cmd("UsercmdSpecEcho " .. usercmd.escape_arg(name), {})
            assert.equals(name, parsed.args[1])
        end
    end)
end)

describe("usercmd.complete_filename", function()
    local tmp, cwd

    before_each(function()
        cwd = vim.fn.getcwd()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(vim.fs.joinpath(tmp, "my dir"), "p")
        vim.fn.mkdir(vim.fs.joinpath(tmp, "other"), "p")
        vim.fn.chdir(tmp)
    end)

    after_each(function()
        vim.fn.chdir(cwd)
        vim.fn.delete(tmp, "rf")
    end)

    it("escapes the spaces getcompletion leaves in", function()
        -- getcompletion accepts the escaped lead but returns the raw name.
        assert.same({ "my\\ dir/" }, usercmd.complete_filename("my\\ d", "dir"))
    end)

    it("escapes every candidate for an empty lead", function()
        assert.same({ "my\\ dir/", "other/" }, usercmd.complete_filename("", "dir"))
    end)

    it("matches when the lead ends in an escaped space", function()
        -- getcompletion returns nothing for "my\ "; the helper rewrites it.
        assert.same({ "my\\ dir/" }, usercmd.complete_filename("my\\ ", "dir"))
    end)
end)

describe("usercmd.complete", function()
    before_each(function()
        vim.api.nvim_create_user_command("UsercmdSpec", function() end, { nargs = "*" })
    end)

    local function subcommand_for(seen)
        return function(cmd, rest, arg_lead)
            seen.cmd, seen.rest, seen.arg_lead = cmd, rest, arg_lead
            return {}
        end
    end

    it("keeps an escaped trailing space in the argument being completed", function()
        local seen = {}
        usercmd.complete("a\\ ", "UsercmdSpec a\\ ", subcommand_for(seen))
        assert.same({}, seen.rest)
        assert.equals("a\\ ", seen.arg_lead)
    end)

    it("treats an unescaped trailing space as a new argument", function()
        local seen = {}
        usercmd.complete("", "UsercmdSpec a ", subcommand_for(seen))
        assert.same({ "a" }, seen.rest)
    end)
end)
