local M = {}

local ksconfig = require('keystone').config
local Process = require("keystone.tools.Process")
local uitools = require("keystone.tools.uitools")
local strtools = require("keystone.tools.strtools")
local filetools = require("keystone.tools.file")
local picker = require('keystone.tools.picker')

---@class keystone.filepicker.fdopts
---@field cwd string The root directory for the search
---@field include_globs string[] List of glob patterns to include (filtered in Lua)
---@field exclude_globs string[] List of glob patterns for fd to ignore
---@field max_results number?

---@param positions integer[] Flat table of pairs: {start1, end1, ...}
---@param offset integer The shift from cropping (#display - #filename)
---@return integer[] # Shifted pairs, discarding any where the start is cropped out
local function _adjust_position_pairs(positions, offset)
    if not positions or #positions == 0 then return {} end
    local adjusted = {}
    for i = 1, #positions, 2 do
        local start_pos = positions[i]
        local end_pos = positions[i + 1]
        -- detect nil values
        if start_pos ~= nil then
            local p_start = start_pos + offset
            if p_start >= 1 then
                table.insert(adjusted, p_start)
                if end_pos then
                    table.insert(adjusted, end_pos + offset)
                end
            end
        end
    end
    return adjusted
end

---@param display string The (potentially cropped) path string
---@param positions integer[] List of matched byte indices
---@return table[] chunks List of { text, hl_group? }
local function _build_label_chunks(display, positions)
    if #positions == 0 then
        return { { display } }
    end

    local chunks = {}
    local pos_map = {}
    for _, p in ipairs(positions) do
        pos_map[p] = true
    end

    local current_chunk = ""
    local last_was_match = pos_map[1] or false

    for i = 1, #display do
        local is_match = pos_map[i] or false

        if is_match ~= last_was_match then
            -- Flush the previous chunk
            table.insert(chunks, last_was_match and { current_chunk, "Label" } or { current_chunk })
            current_chunk = display:sub(i, i)
            last_was_match = is_match
        else
            current_chunk = current_chunk .. display:sub(i, i)
        end
    end

    -- Flush the final chunk
    if current_chunk ~= "" then
        table.insert(chunks, last_was_match and { current_chunk, "Label" } or { current_chunk })
    end

    return chunks
end

---@param query string User input for fuzzy matching
---@param fd_opts keystone.filepicker.fdopts Configuration for directory walking
---@param fetch_opts keystone.Picker.FetcherOpts Layout constraints from the UI
---@param callback fun(items:keystone.SelectorItem[]?) Called when new items are ready
---@return fun() cancel Function to stop the directory walk
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
            if filename:sub(1) == '.' then
                return
            end
            -- 1. Get relative path for matching/display
            local relative_path = full_path:sub(#fd_opts.cwd + 1)
            -- 2. Fuzzy Match
            local is_match, score, positions = strtools.fuzzy_match(filename, query)
            if not is_match then
                return
            end

            -- 3. Limit Check
            if count >= max_results then
                cancel_fn()
                return
            end

            local display = strtools.smart_crop_path(relative_path, fetch_opts.list_width)
            positions = _adjust_position_pairs(positions, #display - #filename)
            local chunks = _build_label_chunks(display, positions)

            -- 4. Prepare UI Item

            table.insert(items, {
                label_chunks = chunks,
                data = full_path,
                score = score, -- Store score if your picker supports sorting
            })
            count = count + 1

            -- 5. Batch updates to the UI
            if #items >= 20 then
                local batch = items
                items = {}
                vim.schedule(function() callback(batch) end)
            end
        end,
        function()
            -- Final Flush
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
---@param opts keystone.filepicker.fdopts
---@return string, string[]
local function get_search_cmd(query, opts)
    local args = { "--type", "f", "--fixed-strings", "--color", "never" }
    -- fd ignores hidden files by default; use --hidden if you wanted them.
    if opts.exclude_globs then
        for _, glob in ipairs(opts.exclude_globs) do
            table.insert(args, "--exclude")
            table.insert(args, glob)
        end
    end
    table.insert(args, "--")
    table.insert(args, query)
    return "fd", args
end

---@param query string User input for literal string matching
---@param fd_opts keystone.filepicker.fdopts Configuration for fd and filtering
---@param fetch_opts keystone.Picker.FetcherOpts Layout constraints from the UI
---@param callback fun(items:keystone.SelectorItem[]?) Called when new items are ready
---@return fun() cancel Function to kill the underlying process
local function async_fd_search(query, fd_opts, fetch_opts, callback)
    assert(fd_opts.cwd, "CWD must be provided for file searching")
    local cmd, args = get_search_cmd(query, fd_opts)

    -- LPeg matchers for include/exclude globs
    local function to_matchers(globs)
        local matchers = {}
        for _, glob in ipairs(globs or {}) do
            local ok, matcher = pcall(vim.glob.to_lpeg, glob)
            if ok then table.insert(matchers, matcher) end
        end
        return matchers
    end

    local include_matchers = to_matchers(fd_opts.include_globs)

    local process
    local read_stop = false
    local count = 0
    local max_results = fd_opts.max_results or 1000

    local buffered_feed = strtools.create_line_buffered_feed(function(lines)
        local items = {}
        for _, line in ipairs(lines) do
            if read_stop then return end

            line = line:gsub("^%.[/]", "")

            -- Apply include globs
            local allowed = (#include_matchers == 0)
            if not allowed then
                for i = 1, #include_matchers do
                    if include_matchers[i]:match(line) then
                        allowed = true
                        break
                    end
                end
            end

            if not allowed then goto continue end

            if count < max_results then
                local path = vim.fs.joinpath(fd_opts.cwd, line)
                local _, _, positions = strtools.fuzzy_match(line, query)
                local display = strtools.smart_crop_path(line, fetch_opts.list_width)
                positions = _adjust_position_pairs(positions, #display - #line)
                local chunks = _build_label_chunks(display, positions)
                table.insert(items, {
                    label_chunks = chunks, -- use chunks instead of label
                    data = path,
                })
                count = count + 1
            else
                process:kill({
                    stop_read = true
                })
                read_stop = true
                break
            end

            ::continue::
        end

        if #items > 0 then
            vim.schedule(function()
                callback(items)
            end)
        end
    end)

    process = Process:new(cmd, {
        cwd = fd_opts.cwd,
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
---@class keystone.filepicker.opts
---@field cwd string? Optional directory to start search (defaults to getcwd)
---@field include_globs string[]? Optional patterns to filter visible files
---@field exclude_globs string[]? Optional patterns for fd to skip (e.g. .git, node_modules)
---@field history_provider keystone.Picker.QueryHistoryProvider?
---@field max_results number?

---Opens a file picker using fd for discovery and LPeg for glob filtering.
---@param opts keystone.filepicker.opts?
function M.open(opts)
    opts = opts or {}

    ---@type keystone.Picker.opts
    local selector_opts = {
        prompt = "Files",
        file_preview = true,
        history_provider = opts.history_provider,
        async_fetch = function(query, fetch_opts, callback)
            -- We only search if there is a query, or you can remove this check
            -- to show all files in the CWD on open.
            if not query or query == "" then
                callback()
                return function() end
            end
            ---@type keystone.filepicker.fdopts
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
        async_preview = function(item_data, preview_opts, callback)
            local filepath = item_data
            local cancel_fn = filetools.async_load_text_file(filepath, nil,
                function(load_err, content)
                    callback(content, {
                        filepath = filepath
                    })
                end)
            return cancel_fn
        end
    }

    return picker.select(selector_opts, function(path)
        if path then
            uitools.smart_open_file(path)
        end
    end)
end

return M
