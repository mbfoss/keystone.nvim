
if vim.fn.has("nvim-0.10") ~= 1 then
    error("keystone.nvim requires Neovim >= 0.10")
end

vim.api.nvim_create_user_command("Keystone", function(opts)
        require("keystone.commands").dispatch(opts)
    end,
    {
        nargs = "*",
        complete = function(arg_lead, cmd_line, _)
            return require("keystone.commands").complete(arg_lead, cmd_line)
        end,
        desc = "keystone.nvim main command",
    })

