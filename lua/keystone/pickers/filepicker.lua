local M = {}

local ksconfig = require('keystone').config
local Process = require("keystone.tools.Process")
local uitools = require("keystone.tools.uitools")
local strtools = require("keystone.tools.strtools")
local filetools = require("keystone.tools.file")
local picker = require('keystone.tools.picker')
local pickertools = require("keystone.pickers.tools")

---@class keystone.filepicker.fdopts
---@field cwd string The root directory for the search
---@field include_globs string[] List of glob patterns to include (filtered in Lua)
---@field exclude_globs string[] List of glob patterns for fd to ignore
---@field max_results number?
---@
---@param query string User input
---@param fd_opts keystone.filepicker.fdopts
---@param fetch_opts keystone.Picker.FetcherOpts
---@param callback fun(items:keystone.SelectorItem[]?)
local function async_lua_search(query, fd_opts, fetch_opts, callback)
    assert(query ~= "")
    local count = 0
    local max_results = fd_opts.max_results or 1000
    local items = {}

    local cancel_fn
    cancel_fn = filetools.async_walk_dir(
        fd_opts.cwd,
        fd_opts.exclude_globs,
        function(full_path, filename)
            if filename:sub(1, 1) == '.' then return end

            local relative_path = full_path:sub(#fd_opts.cwd + 1)

            -- Use generic tool: Match against filename, but display relative_path
            local res = pickertools.make_picker_item(filename, query, relative_path, {
                list_width = fetch_opts.list_width,
                is_path = true,
                offset = #relative_path - #filename
            })

            if not res then return end
            if count >= max_results then
                cancel_fn()
                return
            end

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
---@param fd_opts keystone.filepicker.fdopts
---@param fetch_opts keystone.Picker.FetcherOpts
---@param callback fun(items:keystone.SelectorItem[]?)
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
    local max_results = fd_opts.max_results or 1000

    local buffered_feed = strtools.create_line_buffered_feed(function(lines)
        local items = {}
        for _, line in ipairs(lines) do
            if read_stop then return end
            line = line:gsub("^%.[/]", "")

            if count < max_results then
                -- Match against line (the relative path from fd)
                local res = pickertools.make_picker_item(line, query, line, {
                    list_width = fetch_opts.list_width,
                    is_path = true
                })

                if res then
                    table.insert(items, {
                        label_chunks = res.chunks,
                        data = vim.fs.joinpath(fd_opts.cwd, line),
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

function M.open(opts)
    opts = opts or {}
    return picker.select({
        prompt = "Files",
        file_preview = true,
        history_provider = opts.history_provider,
        async_fetch = function(query, fetch_opts, callback)
            if not query or query == "" then
                callback()
                return function() end
            end
            local fd_opts = {
                cwd = opts.cwd or vim.fn.getcwd(),
                include_globs = opts.include_globs or {},
                exclude_globs = opts.exclude_globs,
                max_results = opts.max_results,
            }
            if ksconfig.use_fd_find then
                return async_fd_search(query, fd_opts, fetch_opts, callback)
            else
                return async_lua_search(query, fd_opts, fetch_opts, callback)
            end
        end,
        async_preview = function(filepath, _, callback)
            return filetools.async_load_text_file(filepath, nil, function(_, content)
                callback(content, { filepath = filepath })
            end)
        end
    }, function(path)
        if path then uitools.smart_open_file(path) end
    end)
end

return M
