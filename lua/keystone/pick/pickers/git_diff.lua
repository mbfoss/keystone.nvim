local M = {}

local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local Process = require("keystone.utils.Process")
local uitools = require("keystone.utils.uitools")
local fsutils = require("keystone.utils.fsutils")
local strutils = require("keystone.utils.strutils")

function M.open()
    local cwd = vim.fn.getcwd()

    local result = vim.system(
        { "git", "diff", "HEAD", "--name-only" },
        { text = true }
    ):wait()

    local lines = vim.split(result.stdout or "", "\n", { trimempty = true })
    if result.code ~= 0 then
        local err = result.stderr and strutils.crop_string_for_ui(result.stderr, 70) or ""
        vim.notify(
            ("git diff failed (exit code %d): %s"):format(result.code, err ~= "" and err or "unknown error"),
            vim.log.levels.ERROR
        )
        return
    end
    if #lines == 0 then
        vim.notify("No changed files (git diff HEAD is empty)", vim.log.levels.INFO)
        return
    end

    picker.open({
        prompt = "Git Diff (Preview Changes)",
        enable_preview = true,
        fetch = function(query, fetch_opts)
            local items = {}
            for _, line in ipairs(lines) do
                local path = fsutils.get_relative_path(line) or line
                local res = pickertools.match_label(path, query)
                if res then
                    table.insert(items, {
                        label_chunks = res.chunks,
                        score = res.score,
                        data = {
                            path = path,
                        }
                    })
                end
            end
            return items
        end,
        async_preview = function(data, _, callback)
            local diff_output = {}
            local filepath = data.path
            local process = Process:new("git", {
                cwd = cwd,
                args = { "diff", "HEAD", "--", filepath },
                on_output = function(data, is_stderr)
                    if data and not is_stderr then table.insert(diff_output, data) end
                end,
                on_exit = function()
                    local content = table.concat(diff_output, "")
                    if content == "" then content = "No changes (staged or unstaged)" end

                    vim.schedule(function()
                        callback({
                            content = content,
                            filetype = "diff",
                        })
                    end)
                end,
            })

            process:start()
            return function() process:kill() end
        end,
    }, function(data)
        if data then
            local full_path = vim.fs.joinpath(cwd, data.path)
            uitools.smart_open_file(full_path)
        end
    end)
end

return M
