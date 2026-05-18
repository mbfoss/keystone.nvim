---@meta

---@class GitStatusEntry
---@field path string
---@field staged boolean
---@field unstaged boolean
---@field untracked boolean
---@field ignored boolean
---@field raw string

---@class PickerItemChunk
---@field text string
---@field hl string

---@class PickerItem
---@field label_chunks PickerItemChunk[]
---@field score number
---@field data GitStatusEntry

---@class PreviewCallbackResult
---@field content string
---@field filetype string

local M = {}

local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local Process = require("keystone.utils.Process")
local uitools = require("keystone.utils.uitools")
local fsutils = require("keystone.utils.fsutils")
local strutils = require("keystone.utils.strutils")

---@local
---@param entries string[]
---@return GitStatusEntry[]
local function parse_porcelain_z(entries)
    local parsed = {}
    local i = 1

    while i <= #entries do
        local entry = entries[i]

        if #entry >= 4 then
            local staged_char = entry:sub(1, 1)
            local unstaged_char = entry:sub(2, 2)
            local path = entry:sub(4)

            if staged_char == "R" or staged_char == "C" or unstaged_char == "R" or unstaged_char == "C" then
                i = i + 1
                path = entries[i]
            end

            table.insert(parsed, {
                path = path,
                staged = staged_char ~= " " and staged_char ~= "?" and staged_char ~= "!",
                unstaged = unstaged_char ~= " " and unstaged_char ~= "?",
                untracked = staged_char == "?" and unstaged_char == "?",
                ignored = staged_char == "!" and unstaged_char == "!",
                raw = entry,
            })
        end
        i = i + 1
    end

    return parsed
end

---@public
function M.open()
    local cwd = vim.fn.getcwd()

    local result = vim.system(
        { "git", "status", "--porcelain=v1", "-z" },
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

    local raw_entries = vim.split(result.stdout or "", "\0", { trimempty = true })
    local parsed = parse_porcelain_z(raw_entries)

    if #parsed == 0 then
        vim.notify("No changed files", vim.log.levels.INFO)
        return
    end

    picker.open({
        prompt = "Git Status",
        enable_preview = true,

        ---@param query string
        ---@param fetch_opts table
        ---@return PickerItem[]
        fetch = function(query, fetch_opts)
            local items = {}

            for _, entry in ipairs(parsed) do
                local path = fsutils.get_relative_path(entry.path) or entry.path
                local res = pickertools.match_label(path, query)

                if res then
                    local chunks = {}
                    if entry.staged then
                        table.insert(chunks, {
                            "[S] ",
                            "DiagnosticOk",
                        })
                    end
                    if entry.unstaged then
                        table.insert(chunks, {
                            "[U] ",
                            "DiagnosticWarn",
                        })
                    end
                    if entry.untracked then
                        table.insert(chunks, {
                            "[?] ",
                            "DiagnosticInfo",
                        })
                    end
                    vim.list_extend(chunks, res.chunks)
                    table.insert(items, {
                        label_chunks = chunks,
                        score = res.score,
                        data = entry,
                    })
                end
            end

            return items
        end,

        ---@param data GitStatusEntry
        ---@param opts table
        ---@param callback fun(result: PreviewCallbackResult)
        ---@return fun() cancel_fn
        async_preview = function(data, opts, callback)
            local filepath = data.path
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
