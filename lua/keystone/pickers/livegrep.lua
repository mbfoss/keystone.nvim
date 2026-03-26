local M = {}

local Process = require("keystone.utils.Process")
local uitools = require("keystone.utils.uitools")
local strtools = require("keystone.utils.strtools")
local picker = require('keystone.utils.picker')
local pickertools = require("keystone.utils.pickertools")

---@class keystone.livegrep.opts
---@field cwd string? Optional directory to start search (defaults to getcwd)
---@field include_globs string[]? Optional patterns to filter visible files
---@field exclude_globs string[]? Optional patterns for fd to skip (e.g. .git, node_modules)
---@field history_provider keystone.Picker.QueryHistoryProvider?
---@field max_results number?

---@param query string
---@param opts keystone.livegrep.opts
---@return string, string[]
local function get_grep_cmd(query, opts)
    local args = {
        "--column",
        "--line-number",
        "--no-heading",
        "--color", "never",
        "--smart-case",
        "--fixed-strings",
    }

    if opts.exclude_globs then
        for _, glob in ipairs(opts.exclude_globs) do
            table.insert(args, "-g")
            table.insert(args, "!" .. glob)
        end
    end

    table.insert(args, "--")
    table.insert(args, query)
    table.insert(args, ".")
    return "rg", args
end

---@param query string
---@param grep_opts keystone.livegrep.opts
---@param fetch_opts keystone.Picker.FetcherOpts
---@param callback fun(items:table[]?)
---@return fun() cancel
local function async_grep_search(query, grep_opts, fetch_opts, callback)
    local cmd, args = get_grep_cmd(query, grep_opts)
    local count = 0
    local process
    local max_results = grep_opts.max_results or 10000
    local read_stop = false
    local lower_query = query:lower()

    local buffered_feed = strtools.create_line_buffered_feed(function(lines)
        local items = {}
        for _, line in ipairs(lines) do
            if read_stop then return end

            -- Parse rg output: file:line:col:text
            local file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
            if not file then
                file, lnum, text = line:match("^(.-):(%d+):(.*)$")
                col = "1"
            end
            if not file or not lnum or not text then goto continue end

            local abs_path = vim.fs.joinpath(grep_opts.cwd, file)
            local location = string.format("%s:%s", file, lnum)
            location = strtools.smart_crop_path(location, fetch_opts.list_width)

            -- Build label_chunks by highlighting all occurrences of the query
            local chunks = {}
            local start_idx = 1
            text = vim.fn.trim(text, "", 0)
            local lower_text = text:lower()
            while true do
                local s, e = lower_text:find(lower_query, start_idx, true)
                if not s then
                    if start_idx <= #text then
                        table.insert(chunks, { text:sub(start_idx) })
                    end
                    break
                end
                if s > start_idx then
                    table.insert(chunks, { text:sub(start_idx, s - 1) })
                end
                table.insert(chunks, { text:sub(s, e), "Label" }) -- your yellow highlight
                start_idx = e + 1
            end

            ---@type keystone.SelectorItem
            local item = {
                label_chunks = chunks,
                virt_lines = { { { location, "@markup" } } },
                file = abs_path,
                data = {
                    filepath = abs_path,
                    lnum = tonumber(lnum),
                    col = tonumber(col),
                }
            }
            table.insert(items, item)
            count = count + 1

            if count >= max_results then
                process:kill({
                    stop_read = true
                })
                read_stop = true
                break
            end

            ::continue::
        end

        if #items > 0 then
            vim.schedule(function() callback(items) end)
        end
    end)

    process = Process:new(cmd, {
        cwd = grep_opts.cwd,
        args = args,
        on_output = function(data, is_stderr)
            if read_stop then return end
            if not data then return end
            if is_stderr then
                vim.notify_once(data, vim.log.levels.ERROR)
                return
            end
            buffered_feed(data)
        end,
        on_exit = function()
            callback(nil)
        end,
    })

    local start_ok, start_err = process:start()
    if not start_ok and start_err and #start_err > 0 then
        callback(nil)
        vim.notify_once(start_err, vim.log.levels.ERROR)
    end

    return function()
        if process then
            process:kill({
                stop_read = true
            })
        end
    end
end

---Opens a file picker using fd for discovery and LPeg for glob filtering.
---@param opts keystone.livegrep.opts?
function M.open(opts)
    opts = opts or {}
    local cwd = opts.cwd or vim.fn.getcwd()

    return picker.select({
        prompt = "Live Grep",
        file_preview = true,
        history_provider = opts.history_provider,
        async_fetch = function(query, fetch_opts, callback)
            if not query or #query < 1 then -- Optimization: don't grep for 1 char
                callback()
                return function() end
            end
            return async_grep_search(query, {
                cwd = cwd,
                include_globs = opts.include_globs or {},
                exclude_globs = opts.exclude_globs or {},
                max_results = opts.max_results or 10000,
            }, fetch_opts, callback)
        end,
            async_preview = function(data, _, callback)
                return pickertools.default_file_preview(data.filepath, {
                    lnum = data.lnum,
                    col = data.col
                }, callback)
            end,
    }, function(selected)
        if selected then
            -- Open file and jump to line/column
            uitools.smart_open_file(selected.filepath, selected.lnum, selected.col - 1)
        end
    end)
end

return M
