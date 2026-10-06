local M = {}

-- The diff session machinery (and its `fsutil` dependency) lives in
-- `keystone.diffunsaved.session`, which is only required the first time the user
-- runs `:DiffUnsaved` -- keeping `setup` to a single lightweight require.

--- Open the diff of unsaved vs saved state for all modified buffers.
function M.open()
    require("keystone.diffunsaved.session").open()
end

local _setup = false

--- Whether `setup()` has been called for this module.
---@return boolean
function M.is_setup()
    return _setup
end

function M.setup()
    _setup = true
    vim.api.nvim_create_user_command("DiffUnsaved", function(cmd_opts)
        -- Errors become notifications, not stack traces.
        local ok, err = pcall(M.open)
        if not ok then
            vim.notify(
                "[keystone.util.nvim] " .. cmd_opts.name .. " command error\n" .. tostring(err),
                vim.log.levels.ERROR
            )
        end
    end, {
        nargs = "*",
        desc = "Diff unsaved vs saved state of all modified buffers",
    })
end

return M
