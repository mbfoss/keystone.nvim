local M = {}

local Process = require("keystone.utils.Process")
local uitools = require("keystone.utils.uitools")
local picker = require('keystone.utils.picker')
local pickertools = require("keystone.utils.pickertools")

function M.open()
    local cwd = vim.fn.getcwd()

    picker.select({
        prompt = "Git Diff (Preview Changes)",
        file_preview = false, -- We handle the diff preview manually below
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
                        local res = pickertools.make_picker_item(line, query, {
                            list_width = fetch_opts.list_width,
                            is_path = true,
                            offset = #line - #filename
                        })

                        if res then
                            table.insert(items, {
                                label_chunks = res.chunks,
                                data = line, -- Relative path for git commands
                                score = res.score
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
