local M = {}

local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local uitools = require("keystone.utils.uitools")
local fsutils = require("keystone.utils.fsutils")

function M.open()
    local bufnr = vim.api.nvim_get_current_buf()
    local file_path = vim.api.nvim_buf_get_name(bufnr)
    file_path = fsutils.get_relative_path(file_path) or file_path

    -- get hunks directly from Gitsigns
    -- This returns a table of hunk objects for the current buffer
    local gs_ok, gs = pcall(require, "gitsigns")
    if not gs_ok then
        vim.notify("Gitsigns not found", vim.log.levels.ERROR)
        return
    end

    local hunks = gs.get_hunks(bufnr)

    if not hunks or #hunks == 0 then
        vim.notify("No git hunks found in current buffer", vim.log.levels.INFO)
        return
    end

    -- 2. Open the picker
    picker.open({
            prompt = "Gitsigns Hunks",
            enable_preview = true,

            fetch = function(query, fetch_opts)
                local items = {}
                for _, h in ipairs(hunks) do
                    -- Gitsigns hunk structure: { added = { count, start }, removed = { count, start }, lines = { ... } }
                    -- h.added.start is the 1-indexed start line
                    local start_line = h.added.start

                    local res = pickertools.match_label(file_path, query)

                    if res then
                        local chunks = { { tostring(start_line), "Number" }, { ": ", "NonText" } }
                        vim.list_extend(chunks, res.chunks or {})

                        table.insert(items, {
                            label_chunks = chunks,
                            score = res.score,
                            data = { hunk = h, path = file_path },
                        })
                    end
                end
                return items
            end,

            async_preview = function(data, _, callback)
                -- Gitsigns hunks already contain the 'lines' (diff strings)
                local content = table.concat(data.hunk.lines, "\n")
                vim.schedule(function()
                    callback({
                        content = content,
                        filetype = "diff",
                    })
                end)
                return function() end
            end,
        },
        function(data)
            if not data then return end
            -- Use the start line from the hunk object to jump
            uitools.smart_open_file(data.path, data.hunk.added.start, 1)
        end)
end

return M
