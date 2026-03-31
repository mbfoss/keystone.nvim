local M = {}

local ksconfig = require('keystone').config
local Process = require("keystone.utils.Process")
local uitools = require("keystone.utils.uitools")
local strtools = require("keystone.utils.strtools")
local filetools = require("keystone.utils.file")
local picker = require('keystone.utils.picker')
local pickertools = require("keystone.utils.pickertools")

---@class keystone.filepicker.Opts
---@field cwd string The root directory for the search
---@field include_globs string[]? List of glob patterns to include (filtered in Lua)
---@field exclude_globs string[]? List of glob patterns for fd to ignore
---@field max_results number?
---@field history_provider keystone.Picker.QueryHistoryProvider?

---@class keystone.filepicker.SearchOpts
---@field cwd string The root directory for the search
---@field include_globs string[]? List of glob patterns to include (filtered in Lua)
---@field exclude_globs string[]? List of glob patterns for fd to ignore
---@field max_results number?

---@param query string User input
---@param opts keystone.filepicker.SearchOpts
---@param fetch_opts keystone.Picker.FetcherOpts
---@param callback fun(items:keystone.SelectorItem[]?)
local function async_lua_search(query, opts, fetch_opts, callback)
    assert(query ~= "")
    local count = 0
    local max_results = opts.max_results or 10000
    local items = {}

    local include_regex_list = opts.include_globs and strtools.compile_globs(opts.include_globs) or nil
    local exclude_regex_list = opts.exclude_globs and strtools.compile_globs(opts.exclude_globs) or nil

    local cancel_fn
    cancel_fn = filetools.async_walk_dir(
        opts.cwd,
        include_regex_list,
        exclude_regex_list,
        function(full_path, filename, relative_path)
            -- Use generic tool: Match against filename, but display relative_path
            local res = pickertools.make_picker_item(relative_path, query, {
                list_width = fetch_opts.list_width,
                is_path = true,
                offset = 0
            })

            if not res then return end
            if count >= max_results then
                cancel_fn()
                return
            end

            --table.insert(res.chunks, 1, {tostring(res.score) .. " - "})
            table.insert(items, {
                label_chunks = res.chunks,
                data = full_path,
                score = res.score,
            })
            count = count + 1

            if #items >= 20 then
                local batch = items
                items = {}
                vim.schedule(function() callback(batch) end)
            end
        end,
        function()
            if #items > 0 then
                vim.schedule(function()
                    callback(items)
                    callback(nil)
                end)
            else
                vim.schedule(function() callback(nil) end)
            end
        end
    )
    return cancel_fn
end

---@param query string
---@param fd_opts keystone.filepicker.SearchOpts
---@param fetch_opts keystone.Picker.FetcherOpts
---@param callback fun(items:keystone.Picker.Item[]?)
local function async_fd_search(query, fd_opts, fetch_opts, callback)
    local args = { "--type", "f", "--fixed-strings", "--color", "never" }
    if fd_opts.exclude_globs then
        for _, glob in ipairs(fd_opts.exclude_globs) do
            table.insert(args, "--exclude")
            table.insert(args, glob)
        end
    end
    table.insert(args, "--")
    table.insert(args, query)

    local process
    local read_stop = false
    local count = 0
    local max_results = fd_opts.max_results or 10000

    local include_regex_list = fd_opts.include_globs and strtools.compile_globs(fd_opts.include_globs) or nil

    local buffered_feed = strtools.create_line_buffered_feed(function(lines)
        local items = {}
        for _, line in ipairs(lines) do
            if read_stop then return end
            local relpath = line:gsub("^%.[/]", "")
            -- line is path relative to fd_opts.cwd
            if strtools.check_path_pattern(line, false, include_regex_list, nil) then
                if count < max_results then
                    -- Match against line (the relative path from fd)
                    local res = pickertools.make_picker_item(relpath, query, {
                        list_width = fetch_opts.list_width,
                        is_path = true
                    })

                    if res then
                        table.insert(items, {
                            label_chunks = res.chunks,
                            data = vim.fs.joinpath(fd_opts.cwd, relpath),
                            score = res.score
                        })
                        count = count + 1
                    end
                else
                    process:kill({ stop_read = true })
                    read_stop = true
                    break
                end
            end
        end

        if #items > 0 then
            vim.schedule(function() callback(items) end)
        end
    end)

    process = Process:new("fd", {
        cwd = fd_opts.cwd,
        args = args,
        on_output = function(data, is_stderr)
            if read_stop or not data then return end
            if is_stderr then return end
            buffered_feed(data)
        end,
        on_exit = function() callback(nil) end,
    })

    process:start()
    return function() if process then process:kill({ stop_read = true }) end end
end

---@param opts keystone.filepicker.Opts?
function M.open(opts)
    opts = opts or {}
    return picker.select({
        prompt = "Files",
        file_preview = true,
        history_provider = opts.history_provider or pickertools.make_history_provider("files"),
        async_fetch = function(query, fetch_opts, callback)
            if not query or query == "" then
                callback()
                return function() end
            end
            ---@type keystone.filepicker.SearchOpts
            local search_opts = {
                cwd = opts.cwd or vim.fn.getcwd(),
                include_globs = opts.include_globs,
                exclude_globs = opts.exclude_globs,
                max_results = opts.max_results or 10000,
            }
            if ksconfig.use_fd_find then
                return async_fd_search(query, search_opts, fetch_opts, callback)
            else
                return async_lua_search(query, search_opts, fetch_opts, callback)
            end
        end,
        async_preview = pickertools.default_file_preview,
    }, function(path)
        if path then uitools.smart_open_file(path) end
    end)
end

return M
