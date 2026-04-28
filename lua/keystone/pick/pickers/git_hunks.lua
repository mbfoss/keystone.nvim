local M = {}

local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local Process = require("keystone.utils.Process")
local uitools = require("keystone.utils.uitools")
local fsutils = require("keystone.utils.fsutils")

---@class GitHunk
---@field file string
---@field header string?
---@field patch string
---@field start_line integer

---@param diff string
---@return GitHunk[]
local function parse_hunks(diff)
    local hunks = {}

    local file = nil
    local header = nil
    local patch = {}
    local start_line = nil

    local function flush()
        if file and header and start_line and #patch > 0 then
            table.insert(hunks, {
                file = file,
                header = header,
                patch = table.concat(patch, ""),
                start_line = start_line,
            })
        end
        patch = {}
        header = nil
        start_line = nil
    end

    for line in diff:gmatch("[^\r\n]+\r?\n") do
        local new_file = line:match("^diff %-%-git a/(.+) b/(.+)")
        if new_file then
            flush()
            file = new_file
        end

        local h = line:match("^@@ [^+]*%+([0-9]+)")
        if h then
            flush()
            header = line:match("^@@.-@@")
            start_line = tonumber(h)
            table.insert(patch, line)
        elseif header then
            table.insert(patch, line)
        end
    end

    flush()
    return hunks
end

---@class PickerItem
---@field label_chunks any
---@field score number
---@field data GitHunk

---@class keystone.pick.git_hunks_opts
---@field cwd string?
---@field current_file boolean?

---@param opts keystone.pick.git_hunks_opts
function M.open(opts)
    opts = opts or {}
    local cwd = opts.cwd or vim.fn.getcwd()

    local git_args = { "diff", "HEAD", "-U0" }
    if opts.current_file then
        local buf_path = vim.api.nvim_buf_get_name(0)
        if buf_path == "" then return end
        local rel_path = fsutils.get_relative_path(buf_path, cwd) or buf_path
        vim.list_extend(git_args, { "--", rel_path })
    end

    picker.open({
        prompt = "Git Hunks",
        file_preview = false,

        ---@param query string
        ---@param fetch_opts table
        ---@param callback fun(items: PickerItem[]|nil)
        async_fetch = function(query, fetch_opts, callback)
            local buf = {}

            local process = Process:new("git", {
                cwd = cwd,
                args = git_args,
                on_output = function(data, is_stderr)
                    if data and not is_stderr then
                        table.insert(buf, data)
                    end
                end,
                on_exit = function()
                    local diff = table.concat(buf, "")
                    local hunks = parse_hunks(diff)

                    local items = {}

                    for _, h in ipairs(hunks) do
                        local label = (h.file .. " @" .. tostring(h.start_line))

                        local res = pickertools.make_picker_item(label, query, {
                            list_width = fetch_opts.list_width,
                        })

                        if res then
                            table.insert(items, {
                                label_chunks = res.chunks,
                                score = res.score,
                                data = h,
                            })
                        end
                    end

                    if query ~= "" then
                        table.sort(items, function(a, b)
                            return a.score > b.score
                        end)
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

        ---@param hunk GitHunk
        async_preview = function(hunk, _, callback)
            vim.schedule(function()
                callback(hunk.patch or "", {
                    filetype = "diff",
                    filepath = hunk.file,
                })
            end)
            return function() end
        end,
    }, function(selected)
        if not selected or not selected.file then
            return
        end

        local path = vim.fs.joinpath(cwd, selected.file)
        local row = selected.start_line or 1

        uitools.smart_open_file(path, row, 1)
    end)
end

return M
