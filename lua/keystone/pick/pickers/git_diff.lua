---@meta

---@class GitStatusEntry
---@field path string
---@field index_status string
---@field worktree_status string
---@field staged boolean
---@field unstaged boolean
---@field untracked boolean
---@field ignored boolean
---@field raw string

local M = {}

local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local Process = require("keystone.utils.Process")
local uitools = require("keystone.utils.uitools")
local fsutils = require("keystone.utils.fsutils")
local strutils = require("keystone.utils.strutils")
local icons = require("keystone.icons")

local STATUS_HL = {
    A = "DiagnosticOk",
    M = "DiagnosticWarn",
    D = "DiagnosticError",
    R = "DiagnosticInfo",
    C = "DiagnosticInfo",
    U = "DiagnosticError",
    ["?"] = "DiagnosticHint",
    ["!"] = "Comment",
    [" "] = "NonText",
}

local function status_hl(char)
    return STATUS_HL[char] or "Normal"
end

local function sort_priority(entry)
    if entry.ignored then return 5 end
    if entry.untracked then return 4 end
    if entry.staged and entry.unstaged then return 2 end
    if entry.staged then return 1 end
    return 3
end

---@local
---@param entries string[]
---@return GitStatusEntry[]
local function parse_porcelain_z(entries)
    local parsed = {}
    local i = 1

    while i <= #entries do
        local entry = entries[i]

        if #entry >= 3 then
            local index_status      = entry:sub(1, 1)
            local worktree_status   = entry:sub(2, 2)
            local path              = entry:sub(4)

            local is_rename_or_copy =
                index_status == "R" or index_status == "C"
                or worktree_status == "R" or worktree_status == "C"

            if is_rename_or_copy then
                local dst = entries[i + 1]
                if dst then
                    path = dst
                    i = i + 1
                end
            end

            table.insert(parsed, {
                path            = path,
                index_status    = index_status,
                worktree_status = worktree_status,
                staged          = index_status ~= " " and index_status ~= "?" and index_status ~= "!",
                unstaged        = worktree_status ~= " " and worktree_status ~= "?" and worktree_status ~= "!",
                untracked       = index_status == "?" and worktree_status == "?",
                ignored         = index_status == "!" and worktree_status == "!",
                raw             = entry,
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
            ("git status failed (exit code %d): %s"):format(result.code, err ~= "" and err or "unknown error"),
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
        table.insert(raw_entries, raw_output:sub(start, nxt - 1))
        start = nxt + 1
    end

    local parsed = parse_porcelain_z(raw_entries)

    if #parsed == 0 then
        vim.notify("No changed files", vim.log.levels.INFO)
        return
    end

    table.sort(parsed, function(a, b)
        local pa, pb = sort_priority(a), sort_priority(b)
        if pa ~= pb then return pa < pb end
        return a.path < b.path
    end)

    picker.open({
        prompt         = "Git Status",
        enable_preview = true,
        finder         = function(query, _, fetch_opts, callback)
            local items = {}

            for _, entry in ipairs(parsed) do
                local path         = entry.path
                local filename     = vim.fn.fnamemodify(path, ":t")
                local dirpart      = vim.fn.fnamemodify(path, ":h")
                dirpart            = (dirpart == "." or dirpart == "") and "" or (dirpart .. "/")

                local match_target = fsutils.get_relative_path(path) or path
                local res          = pickertools.match_label(filename ~= "" and filename or match_target, query)
                if not res then goto continue end

                local x = entry.index_status
                local y = entry.worktree_status
                local icon, icon_hl = icons.get_icon(filename)

                local chunks = {
                    { x,    status_hl(x) },
                    { y,    status_hl(y) },
                    { "  ", "Normal" },
                    { icon, icon_hl },
                    { " ",  "Normal" },
                }

                if dirpart ~= "" then
                    table.insert(chunks, { dirpart, "Comment" })
                end

                vim.list_extend(chunks, res.chunks)

                table.insert(items, {
                    label_chunks = chunks,
                    score        = res.score,
                    data         = entry,
                })

                ::continue::
            end

            callback(items)
        end,

        previewer      = function(data, opts, callback)
            if data.untracked then
                vim.schedule(function()
                    callback({ filepath = vim.fs.joinpath(cwd, data.path) })
                end)
                return function() end
            end

            local diff_output = {}
            local args
            if data.staged and not data.unstaged then
                args = { "diff", "--cached", "--", data.path }
            elseif data.unstaged and not data.staged then
                args = { "diff", "--", data.path }
            else
                args = { "diff", "HEAD", "--", data.path }
            end

            local process = Process:new("git", {
                cwd       = cwd,
                args      = args,
                on_output = function(chunk, is_stderr)
                    if chunk and not is_stderr then
                        table.insert(diff_output, chunk)
                    end
                end,
                on_exit   = function()
                    local content = table.concat(diff_output, "")
                    if content == "" then content = "No diff available" end
                    vim.schedule(function()
                        callback({ content = content, filetype = "diff" })
                    end)
                end,
            })
            process:start()
            return function() process:kill() end
        end,
    }, function(data)
        if data then
            uitools.smart_open_file(vim.fs.joinpath(cwd, data.path))
        end
    end)
end

return M
