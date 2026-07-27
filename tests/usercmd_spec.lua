local usercmd = require("keystone.util.usercmd")

describe("register_user_cmd", function()
    local calls
    local candidates

    ---Complete `line` through the registered command, recording what the
    ---subcommand callback was handed.
    ---@param line string
    ---@return string[]
    local function complete(line)
        return vim.fn.getcompletion(line, "cmdline")
    end

    before_each(function()
        calls      = {}
        candidates = {}
        usercmd.register_user_cmd("KeystoneProbe", function() end, {
            subcommand = function(cmd, rest, arg_lead)
                table.insert(calls, { cmd = cmd, rest = rest, arg_lead = arg_lead })
                return candidates
            end,
        })
    end)

    after_each(function()
        vim.api.nvim_del_user_command("KeystoneProbe")
    end)

    describe("dispatch", function()
        it("passes fargs through, split by Vim's <f-args> rules", function()
            local got
            usercmd.register_user_cmd("KeystoneProbeRun", function(_, args) got = args end)

            vim.cmd([[KeystoneProbeRun a\ b c]])
            assert.same({ "a b", "c" }, got)

            vim.cmd([[KeystoneProbeRun a\\b "q r"]])
            assert.same({ [[a\b]], [["q]], [[r"]] }, got)

            vim.cmd("KeystoneProbeRun")
            assert.same({}, got)

            vim.api.nvim_del_user_command("KeystoneProbeRun")
        end)

        it("reports a failing run function instead of throwing", function()
            local notified
            local notify = vim.notify
            vim.notify = function(msg) notified = msg end

            usercmd.register_user_cmd("KeystoneProbeErr", function() error("boom") end)
            vim.cmd("KeystoneProbeErr")
            vim.notify = notify
            vim.api.nvim_del_user_command("KeystoneProbeErr")

            assert.is_truthy(notified and notified:match("KeystoneProbeErr command error"))
            assert.is_truthy(notified:match("boom"))
        end)
    end)

    describe("completion", function()
        it("passes no context for the first argument", function()
            candidates = { "open", "close" }
            assert.same({ "open", "close" }, complete("KeystoneProbe "))
            assert.same("KeystoneProbe", calls[1].cmd)
            assert.same({}, calls[1].rest)
            assert.same("", calls[1].arg_lead)
        end)

        it("filters candidates by the argument being typed", function()
            candidates = { "open", "close" }
            assert.same({ "close" }, complete("KeystoneProbe cl"))
            assert.same({}, calls[1].rest)
            assert.same("cl", calls[1].arg_lead)
        end)

        it("treats preceding arguments as context, excluding the one being typed", function()
            candidates = { "left", "right" }
            assert.same({ "left", "right" }, complete("KeystoneProbe open ri"))
            assert.same({ "open" }, calls[1].rest)
            assert.same("ri", calls[1].arg_lead)

            complete("KeystoneProbe open right ")
            assert.same({ "open", "right" }, calls[2].rest)
            assert.same("", calls[2].arg_lead)
        end)

        it("splits context arguments by Vim's <f-args> rules", function()
            complete([[KeystoneProbe a\ b c\\d ]])
            assert.same({ "a b", [[c\d]] }, calls[1].rest)
        end)

        it("ignores a range or command modifiers before the command", function()
            candidates = { "open" }
            assert.same({ "open" }, complete("silent KeystoneProbe op"))
            assert.same("KeystoneProbe", calls[1].cmd)
            assert.same({}, calls[1].rest)
        end)

        it("offers nothing when no subcommand source is registered", function()
            usercmd.register_user_cmd("KeystoneProbeBare", function() end)
            assert.same({}, complete("KeystoneProbeBare "))
            vim.api.nvim_del_user_command("KeystoneProbeBare")
        end)
    end)
end)
