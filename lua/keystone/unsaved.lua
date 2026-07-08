local M       = {}

local usercmd = require("keystone.tk.usercmd")

-- The diff session machinery (and its `fsutil` dependency) lives in
-- `keystone.unsaved.session`, which is only required the first time the user
-- runs `:DiffUnsaved` -- keeping `setup` to a single lightweight require.

--- Open the diff of unsaved vs saved state for all modified buffers.
function M.open()
    require("keystone.unsaved.session").open()
end

function M.setup()
    usercmd.register_user_cmd("DiffUnsaved", function()
        M.open()
    end, {
        desc = "Diff unsaved vs saved state of all modified buffers",
    })
end

return M
