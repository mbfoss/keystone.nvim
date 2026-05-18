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

            async_preview = function(data, opts, callback)
                local hunk = data.hunk
                -- amount of surrounding context to show
                local context = math.max(math.floor((opts.viewport_height - #hunk.lines) / 2), 2)
                local start_line = hunk.added.start
                local end_line = start_line + math.max(hunk.added.count - 1, 0)
                -- fetch surrounding buffer lines
                local before_start = math.max(start_line - context, 1)
                local before =
                    vim.api.nvim_buf_get_lines(bufnr, before_start - 1, start_line - 1, false)
                local after =
                    vim.api.nvim_buf_get_lines(bufnr, end_line, end_line + context, false)
                local content = {}
                -- unchanged context before
                for _, line in ipairs(before) do
                    table.insert(content, " " .. line)
                end
                -- original diff hunk lines
                vim.list_extend(content, hunk.lines)
                -- unchanged context after
                for _, line in ipairs(after) do
                    table.insert(content, " " .. line)
                end
                vim.schedule(function()
                    callback({
                        content = table.concat(content, "\n"),
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
