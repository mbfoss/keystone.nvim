local M = {}

local Process = require("keystone.utils.Process")
local uitools = require("keystone.utils.uitools")
local strutils = require("keystone.utils.strutils")
local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local fsutils = require("keystone.utils.fsutils")

---@class keystone.livegrep.opts
---@field cwd string? Optional directory to start search (defaults to getcwd)
---@field include_globs string[]? Optional patterns to filter visible files
---@field exclude_globs string[]? Optional patterns for fd to skip (e.g. .git, node_modules)
---@field history_provider keystone.Picker.QueryHistoryProvider?
---@field max_results number?

---@param query string
---@return table[]
local function get_query_highlights(query)
    local highlights = {}
    local start_search = 1

    while true do
        local s, e, prefix = query:find("%f[%w](%a+):%S*", start_search)
        if not s then break end
        if prefix == "path" or prefix == "in" then
            local colon_pos = s + #prefix
            table.insert(highlights, {
                start = s - 1,
                finish = colon_pos - 1,
                hl = "Keyword",
            })
            if e >= colon_pos then
                table.insert(highlights, {
                    start = colon_pos,
                    finish = e,
                    hl = "String",
                })
            end
        end
        start_search = e + 1
    end
    return highlights
end

---@param query string
---@return string, string[]
local function parse_query_and_globs(query)
    local include_globs = {}
    local patterns = { "path:", "in:" }

    for _, pat in ipairs(patterns) do
        for glob in query:gmatch("%f[%w]" .. pat .. "(%S+)") do
            if not glob:match("[%*%./\\]") then
                glob = "*" .. glob .. "*"
            end
            table.insert(include_globs, glob)
        end
    end

    local cleaned = query
    for _, pat in ipairs(patterns) do
        cleaned = cleaned:gsub("%f[%w]" .. pat .. "%S*", "")
    end

    cleaned = cleaned:gsub("\\(.)", "%1")
    cleaned = vim.trim(cleaned:gsub("%s+", " "))
    return cleaned, include_globs
end

---@param query string
---@param opts keystone.livegrep.opts
---@return string, string[], string cleaned_query
local function get_grep_cmd(query, opts)
    local cleaned_query, inline_globs = parse_query_and_globs(query)

    -- merge inline + opts globs
    local include_globs = vim.list_extend(
        vim.deepcopy(opts.include_globs or {}),
        inline_globs
    )

    local args = {
        "--column",
        "--line-number",
        "--no-heading",
        "--color", "never",
        "--smart-case",
        "--fixed-strings",
        "--glob-case-insensitive",
    }

    -- include globs
    for _, glob in ipairs(include_globs) do
        table.insert(args, "-g")
        table.insert(args, glob)
    end

    -- exclude globs
    if opts.exclude_globs then
        for _, glob in ipairs(opts.exclude_globs) do
            table.insert(args, "-g")
            table.insert(args, "!" .. glob)
        end
    end

    table.insert(args, "--")
    table.insert(args, cleaned_query)
    table.insert(args, ".")

    return "rg", args, cleaned_query
end

---@param query string
---@param grep_opts keystone.livegrep.opts
---@param fetch_opts keystone.Picker.FetcherOpts
---@param callback fun(items:table[]?)
---@return fun() cancel
local function async_grep_search(query, grep_opts, fetch_opts, callback)
    local cmd, args, cleaned_query = get_grep_cmd(query, grep_opts)
    if cleaned_query == "" then
        callback()
        return function() end
    end

    local count = 0
    local process
    local max_results = grep_opts.max_results or 10000
    local read_stop = false
    local lower_query = cleaned_query:lower()

    local buffered_feed = strutils.create_line_buffered_feed(function(lines)
        local items = {}
        for _, line in ipairs(lines) do
            if read_stop then return end
            local file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
            if not file then
                file, lnum, text = line:match("^(.-):(%d+):(.*)$")
                col = "1"
            end
            if not file or not lnum or not text then goto continue end

            local abs_path = vim.fs.joinpath(grep_opts.cwd, file)
            local rel_path = fsutils.get_relative_path(abs_path)
            local location = string.format("%s:%s", rel_path, lnum)
            location = fsutils.smart_crop_path(location, fetch_opts.list_width)
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

            ---@type keystone.Picker.Item
            local item = {
                label_chunks = chunks,
                virt_lines = { { { location, "Special" } } },
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
---@param opts keystone.livegrep.opts?
function M.open(opts)
    opts = opts or {}
    local cwd = opts.cwd or vim.fn.getcwd()

    return picker.open({
        prompt = "Live Grep",
        highlight_query = get_query_highlights,
        file_preview = true,
        history_provider = opts.history_provider or pickertools.make_history_provider("grep"),
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
            uitools.smart_open_file(selected.filepath, selected.lnum, selected.col - 1)
        end
    end)
end

return M
