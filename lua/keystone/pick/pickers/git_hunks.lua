local M = {}

local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local Process = require("keystone.utils.Process")
local uitools = require("keystone.utils.uitools")
local fsutils = require("keystone.utils.fsutils")
local strutils = require("keystone.utils.strutils")

---@class keystone.pick.git_hunks_opts
---@field cwd string?
---@field current_file boolean?

---@private
---@class keystone.pick.git_hunks.hunk
---@field file string
---@field header string?
---@field patch string
---@field start_line integer

---@param diff string
---@return keystone.pick.git_hunks.hunk[]
local function parse_hunks(diff)
    local hunks = {}

    local file, header, patch, start_line = nil, nil, {}, nil

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

    local result = vim.system(
        vim.list_extend({ "git" }, git_args),
        { cwd = cwd, text = true }
    ):wait()

    if result.code ~= 0 then
        local err = result.stderr and strutils.crop_string_for_ui(result.stderr, 70) or ""
        vim.notify(
            ("git diff failed (exit code %d): %s"):format(result.code, err ~= "" and err or "unknown error"),
            vim.log.levels.ERROR
        )
        return
    end

    local diff = result.stdout or ""
    if diff == "" then
        vim.notify("No git hunks found", vim.log.levels.INFO)
        return
    end

    local hunks = parse_hunks(diff)
    if #hunks == 0 then
        vim.notify("No git hunks parsed", vim.log.levels.INFO)
        return
    end

    picker.open({
            prompt = "Git Hunks",
            enable_preview = true,

            fetch = function(query, fetch_opts)
                local items = {}

                for _, h in ipairs(hunks) do
                    local res = pickertools.match_label(h.file, query, {
                        maxlen = fetch_opts.list_width - 7,
                        is_path = true,
                    })
                    if res then
                        local chunks = { { tostring(h.start_line), "Number" }, { ":", "NonText" } }
                        vim.list_extend(chunks, res.chunks or {})
                        table.insert(items, {
                            label_chunks = chunks,
                            score = res.score,
                            data = { hunk = h },
                        })
                    end
                end

                if query ~= "" then
                    table.sort(items, function(a, b)
                        return a.score > b.score
                    end)
                end

                return items
            end,

            async_preview = function(item, _, callback)
                assert(item)
                ---@type keystone.pick.git_hunks.hunk
                local hunk = item.hunk
                local diff_output = {}
                local process = Process:new("git", {
                    cwd = cwd,
                    args = { "diff", "HEAD", "--", hunk.file },
                    on_output = function(data, is_stderr)
                        if data and not is_stderr then
                            table.insert(diff_output, data)
                        end
                    end,
                    on_exit = function()
                        local content = table.concat(diff_output, "")
                        if content == "" then content = "No changes" end

                        local parsed = parse_hunks(content)

                        local target_index = 1
                        local line_cursor = 0

                        for _, ph in ipairs(parsed) do
                            local lines = vim.split(ph.patch, "\n", { plain = true })

                            if ph.start_line == hunk.start_line then
                                -- Prefer first actual change line (+/-)
                                local found = false
                                for i, l in ipairs(lines) do
                                    if l:match("^[+-]") then
                                        target_index = line_cursor + i
                                        found = true
                                        break
                                    end
                                end

                                -- fallback to hunk start
                                if not found then
                                    target_index = line_cursor + 1
                                end

                                break
                            end

                            line_cursor = line_cursor + #lines
                        end

                        vim.schedule(function()
                            callback({
                                content = content,
                                filetype = "diff",
                                lnum = target_index,
                            })
                        end)
                    end,
                })

                process:start()
                return function() process:kill() end
            end,
        },
        function(data)
            if not data then return end
            ---@type keystone.pick.git_hunks.hunk
            local hunk = data.hunk
            if not hunk or not hunk.file then return end
            local path = vim.fs.joinpath(cwd, hunk.file)
            local row = hunk.start_line or 1
            uitools.smart_open_file(path, row, 1)
        end)
end

return M
