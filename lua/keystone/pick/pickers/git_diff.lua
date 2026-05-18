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
        { "git", "status", "--porcelain" },
        { text = true }
    ):wait()

    if result.code ~= 0 then
        local err = result.stderr and strutils.crop_string_for_ui(result.stderr, 70) or ""

        vim.notify(
            ("git status failed (exit code %d): %s"):format(
                result.code,
                err ~= "" and err or "unknown error"
            ),
            vim.log.levels.ERROR
        )

        return
    end

    local parsed = {}

    for _, line in ipairs(vim.split(result.stdout or "", "\n", { trimempty = true })) do
        local staged_char = line:sub(1, 1)
        local unstaged_char = line:sub(2, 2)

        local path = vim.trim(line:sub(4))

        -- handle rename format: "old -> new"
        if path:find(" -> ", 1, true) then
            path = vim.split(path, " -> ")[2]
        end

        table.insert(parsed, {
            path = path,
            staged = staged_char ~= " " and staged_char ~= "?",
            unstaged = unstaged_char ~= " ",
            untracked = staged_char == "?" and unstaged_char == "?",
            raw = line,
        })
    end

    if #parsed == 0 then
        vim.notify("No changed files", vim.log.levels.INFO)
        return
    end

    picker.open({
        prompt = "Git Status",
        enable_preview = true,

        fetch = function(query, fetch_opts)
            local items = {}

            for _, entry in ipairs(parsed) do
                local path = fsutils.get_relative_path(entry.path) or entry.path
                local res = pickertools.match_label(path, query)

                if res then
                    local prefix = {}
                    if entry.staged then
                        table.insert(prefix, {
                            text = "[S] ",
                            hl = "DiagnosticOk",
                        })
                    end
                    if entry.unstaged then
                        table.insert(prefix, {
                            text = "[U] ",
                            hl = "DiagnosticWarn",
                        })
                    end
                    if entry.untracked then
                        table.insert(prefix, {
                            text = "[?] ",
                            hl = "DiagnosticInfo",
                        })
                    end
                    table.insert(items, {
                        prefix_chunks = prefix,
                        label_chunks = res.chunks,
                        score = res.score,
                        data = entry,
                    })
                end
            end

            return items
        end,

        async_preview = function(data, _, callback)
            local filepath = data.path
            -- untracked files cannot be diffed
            if data.untracked then
                vim.schedule(function()
                    callback({
                        content = "Untracked file",
                        filetype = "text",
                    })
                end)
                return function() end
            end
            local diff_output = {}
            local args
            if data.staged and not data.unstaged then
                args = { "diff", "--cached", "--", filepath }
            elseif data.unstaged and not data.staged then
                args = { "diff", "--", filepath }
            else
                -- both staged + unstaged
                args = { "diff", "HEAD", "--", filepath }
            end
            local process = Process:new("git", {
                cwd = cwd,
                args = args,
                on_output = function(chunk, is_stderr)
                    if chunk and not is_stderr then
                        table.insert(diff_output, chunk)
                    end
                end,
                on_exit = function()
                    local content = table.concat(diff_output, "")
                    if content == "" then
                        content = "No diff available"
                    end
                    vim.schedule(function()
                        callback({
                            content = content,
                            filetype = "diff",
                        })
                    end)
                end,
            })
            process:start()
            return function()
                process:kill()
            end
        end,
    }, function(data)
        if data then
            local full_path = vim.fs.joinpath(cwd, data.path)
            uitools.smart_open_file(full_path)
        end
    end)
end

return M
