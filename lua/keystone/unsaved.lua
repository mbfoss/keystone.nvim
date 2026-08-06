local M = {}

-- The diff session machinery (and its `fsutil` dependency) lives in
-- `keystone.unsaved.session`, which is only required the first time the user
-- runs `:DiffUnsaved` -- keeping `setup` to a single lightweight require.

--- Open the diff of unsaved vs saved state for all modified buffers.
function M.open()
    require("keystone.unsaved.session").open()
end

function M.setup()
    vim.api.nvim_create_user_command("DiffUnsaved", function(cmd_opts)
        require("keystone.util.usercmd").handle(cmd_opts, function() M.open() end)
    end, {
        nargs = "*",
        desc = "Diff unsaved vs saved state of all modified buffers",
    })
end

return M
