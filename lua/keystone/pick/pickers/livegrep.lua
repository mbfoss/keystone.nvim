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
        if prefix == "glob" or prefix == "in" then
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
    local patterns = { "glob", "in" }
    local cleaned = query
    -- extract values
    for _, pat in ipairs(patterns) do
        for filter in cleaned:gmatch("%f[%w]" .. pat .. ":(%S+)") do
            if pat == "glob" then
                table.insert(include_globs, filter)
            elseif pat == "in" then
                filter = filter:gsub("^!", "\\!") -- escape leading !
                filter = filter:gsub("^%*+", ""):gsub("%*+$", "")
                filter = filter:gsub("^%/+", ""):gsub("%/+$", "")
                table.insert(include_globs, "*" .. filter .. "*")
                table.insert(include_globs, "**/" .. filter .. "/**")
            end
        end
    end
    -- remove patterns
    for _, pat in ipairs(patterns) do
        cleaned = cleaned:gsub("()(%s*%f[%w]" .. pat .. ":%S+%s*)()", function(start_pos, match, end_pos)
            local at_start = (start_pos == 1)
            local at_end = (end_pos > #cleaned)
            if at_start or at_end then
                return ""
            end
            return " "
        end)
    end
    return cleaned, include_globs
end

---@param line string
---@return string|nil file, integer|nil lnum, integer|nil col, string[]? chunks
local function parse_rg_json(line)
    local ok, decoded = pcall(vim.json.decode, line)
    if not ok or not decoded then return end

    if decoded.type ~= "match" then return end

    local data = decoded.data
    local path = data.path and data.path.text or nil
    local lnum = data.line_number
    local submatches = data.submatches or {}

    local text = data.lines.text or data.lines.bytes or ""
    local chunks = {}

    local last_idx = 1

    for _, m in ipairs(submatches) do
        local s = m.start + 1
        local e = m["end"]

        -- non-highlight
        if s > last_idx then
            table.insert(chunks, { text:sub(last_idx, s - 1) })
        end

        -- highlight
        table.insert(chunks, { text:sub(s, e), "Label" })

        last_idx = e + 1
    end

    -- trailing text
    if last_idx <= #text then
        table.insert(chunks, { text:sub(last_idx) })
    end

    -- column: take first match if exists
    local col = submatches[1] and (submatches[1].start + 1) or 1

    return path, lnum, col, chunks
end

---@param query string
---@param opts keystone.livegrep.opts
---@return string, string[], string cleaned_query
local function get_grep_cmd(query, opts)
    local cleaned_query, inline_globs = parse_query_and_globs(query)
    --vim.notify(string.format("qery:'%s'\nglobs:%s", cleaned_query, vim.inspect(inline_globs)))

    -- merge inline + opts globs
    local include_globs = vim.list_extend(
        vim.deepcopy(opts.include_globs or {}),
        inline_globs
    )

    local args = {
        "--json",
        "--no-heading",
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

    local buffered_feed = strutils.create_line_buffered_feed(function(lines)
        local items = {}
        for _, line in ipairs(lines) do
            if read_stop then return end
            local file, lnum, col, chunks = parse_rg_json(line)
            if chunks then
                local abs_path = vim.fs.joinpath(grep_opts.cwd, file or "")
                local rel_path = fsutils.get_relative_path(abs_path)
                local location = string.format("%s:%s", rel_path, lnum)
                location = fsutils.smart_crop_path(location, fetch_opts.list_width)
                ---@type keystone.Picker.Item
                local item = {
                    label_chunks = chunks,
                    virt_lines = { { { location, "Special" } } },
                    filepath = abs_path,
                    lnum = tonumber(lnum),
                    col = tonumber(col),
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
            end
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
        enable_preview = true,
        enable_list_sep = true,
        history_provider = opts.history_provider or pickertools.make_history_provider("grep"),
        async_fetch = function(query, fetch_opts, callback)
            return async_grep_search(query, {
                cwd = cwd,
                include_globs = opts.include_globs or {},
                exclude_globs = opts.exclude_globs or {},
                max_results = opts.max_results or 10000,
            }, fetch_opts, callback)
        end,
    }, function(selected)
        if selected then
            uitools.smart_open_file(selected.filepath, selected.lnum, selected.col - 1)
        end
    end)
end

return M
