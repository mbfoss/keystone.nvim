local M = {}

local Process = require("keystone.tools.Process")
local uitools = require("keystone.tools.uitools")
local strtools = require("keystone.tools.strtools")
local picker = require('keystone.tools.picker')

-- Reusing your existing chunk builder for consistency
local function _build_label_chunks(display, positions)
    if not positions or #positions == 0 then return { { display } } end
    local chunks, pos_map = {}, {}
    for _, p in ipairs(positions) do pos_map[p] = true end
    local current_chunk = ""
    local last_was_match = pos_map[1] or false
    for i = 1, #display do
        local is_match = pos_map[i] or false
        if is_match ~= last_was_match then
            table.insert(chunks, last_was_match and { current_chunk, "Label" } or { current_chunk })
            current_chunk = display:sub(i, i)
            last_was_match = is_match
        else
            current_chunk = current_chunk .. display:sub(i, i)
        end
    end
    if current_chunk ~= "" then
        table.insert(chunks, last_was_match and { current_chunk, "Label" } or { current_chunk })
    end
    return chunks
end

function M.open()
    local cwd = vim.fn.getcwd()

    picker.select({
        prompt = "Git Diff (Preview Changes)",
        -- Disable file_preview if it forces a specific syntax highlighting
        -- that interferes with the diff colorization
        file_preview = false,
        async_fetch = function(query, fetch_opts, callback)
            local items = {}
            local args = { "diff", "HEAD", "--name-only" }

            local process = Process:new("git", {
                cwd = cwd,
                args = args,
                on_output = function(data, is_stderr)
                    if not data or is_stderr then return end
                    for line in data:gmatch("[^\r\n]+") do
                        local filename = vim.fn.fnamemodify(line, ":t")
                        local is_match, score, positions = strtools.fuzzy_match(filename, query)

                        if is_match or query == "" then
                            local display = strtools.smart_crop_path(line, fetch_opts.list_width)
                            local filename_start_in_rel = #line - #filename
                            local crop_offset = #display - #line

                            local adjusted_positions = {}
                            if positions then
                                for _, p in ipairs(positions) do
                                    local adj = p + filename_start_in_rel + crop_offset
                                    if adj >= 1 then table.insert(adjusted_positions, adj) end
                                end
                            end

                            table.insert(items, {
                                label_chunks = _build_label_chunks(display, adjusted_positions),
                                -- Store the relative path for the diff command
                                data = line,
                                score = score or 0
                            })
                        end
                    end
                end,
                on_exit = function()
                    if query ~= "" then
                        table.sort(items, function(a, b) return a.score > b.score end)
                    end
                    vim.schedule(function()
                        callback(items)
                        callback(nil)
                    end)
                end,
            })

            process:start()
            return function() process:kill() end
        end,
        async_preview = function(relative_path, _, callback)
            local diff_output = {}

            -- Run git diff for the specific file
            local process = Process:new("git", {
                cwd = cwd,
                args = { "diff", "HEAD", "--", relative_path },
                on_output = function(data, is_stderr)
                    if data and not is_stderr then table.insert(diff_output, data) end
                end,
                on_exit = function()
                    local content = table.concat(diff_output, "")
                    if content == "" then content = "No changes (staged or unstaged)" end

                    vim.schedule(function()
                        callback(content, {
                            -- Setting the filetype to 'diff' enables
                            -- built-in syntax highlighting in the preview window
                            filetype = "diff",
                            filepath = relative_path
                        })
                    end)
                end,
            })

            process:start()
            return function() process:kill() end
        end,
    }, function(selected_rel_path)
        if selected_rel_path then
            local full_path = vim.fs.joinpath(cwd, selected_rel_path)
            uitools.smart_open_file(full_path)
        end
    end)
end

return M
