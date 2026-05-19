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

        if #entry >= 3 then
            local index_status = entry:sub(1, 1)
            local worktree_status = entry:sub(2, 2)

            local path = entry:sub(4)

            local is_rename_or_copy =
                index_status == "R"
                or index_status == "C"
                or worktree_status == "R"
                or worktree_status == "C"

            if is_rename_or_copy then
                local dst = entries[i + 1]

                if dst then
                    path = dst
                    i = i + 1
                end
            end

            table.insert(parsed, {
                path = path,

                index_status = index_status,
                worktree_status = worktree_status,

                staged = index_status ~= " "
                    and index_status ~= "?"
                    and index_status ~= "!",

                unstaged = worktree_status ~= " "
                    and worktree_status ~= "?"
                    and worktree_status ~= "!",

                untracked = index_status == "?"
                    and worktree_status == "?",

                ignored = index_status == "!"
                    and worktree_status == "!",

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
        { true }
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

    local raw_output = result.stdout or ""
    local raw_entries = {}

    local start = 1
    while true do
        local nxt = raw_output:find("\0", start, true)
        if not nxt then break end

        local entry = raw_output:sub(start, nxt - 1)
        table.insert(raw_entries, entry)
        start = nxt + 1
    end

    local parsed = parse_porcelain_z(raw_entries)

    if #parsed == 0 then
        vim.notify("No changed files", vim.log.levels.INFO)
        return
    end

    local max_flags = 1
    for _, entry in ipairs(parsed) do
        local count = 0
        if entry.staged then count = count + 1 end
        if entry.unstaged then count = count + 1 end
        if entry.untracked then count = count + 1 end
        if entry.ignored then count = count + 1 end
        if count > max_flags then
            max_flags = count
        end
    end

    picker.open({
        prompt = "Git Status",
        enable_preview = true,

        ---@param query string
        ---@param fetch_opts table
        ---@return PickerItem[]
        finder = function(query, fetch_opts, callback)
            local items = {}

            for _, entry in ipairs(parsed) do
                local path = fsutils.get_relative_path(entry.path) or entry.path
                local res = pickertools.match_label(path, query)

                if res then
                    local chunks = {}
                    local active_flags = {}
                    if entry.staged then
                        table.insert(active_flags, { "[S]", "DiagnosticOk" })
                    end
                    if entry.unstaged then
                        table.insert(active_flags, { "[U]", "DiagnosticWarn" })
                    end
                    if entry.untracked then
                        table.insert(active_flags, { "[?]", "DiagnosticInfo" })
                    end
                    if entry.ignored then
                        table.insert(active_flags, { "[I]", "Comment" })
                    end

                    for _, flag in ipairs(active_flags) do
                        table.insert(chunks, flag)
                    end

                    local padding = max_flags - #active_flags
                    if padding > 0 then
                        table.insert(chunks, { string.rep("   ", padding), "Normal" })
                    end

                    table.insert(chunks, { " ", "Normal" })

                    vim.list_extend(chunks, res.chunks)
                    table.insert(items, {
                        label_chunks = chunks,
                        score = res.score,
                        data = entry,
                    })
                end
            end

            callback(items)
        end,

        ---@param data GitStatusEntry
        ---@param opts table
        ---@param callback fun(result: PreviewCallbackResult)
        ---@return fun() cancel_fn
        previewer = function(data, opts, callback)
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
