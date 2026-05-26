local M = {}

local Process    = require("keystone.utils.Process")
local uitools    = require("keystone.utils.uitools")
local strutils   = require("keystone.utils.strutils")
local picker     = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local fsutils    = require("keystone.utils.fsutils")
local throttle   = require("keystone.utils.throttle")

---@class keystone.livegrep.opts
---@field cwd           string?   -- defaults to getcwd
---@field include_globs string[]?
---@field exclude_globs string[]?
---@field history_provider keystone.Picker.QueryHistoryProvider?
---@field max_results   number?

---@type keystone.queryflags.FlagDef[]
local FLAGS = {
    { name = "glob",  type = "value",   multi = true, desc = "include glob pattern" },
    { name = "in",    type = "value",   multi = true, desc = "restrict to path"     },
    { name = "regex", type = "boolean",               desc = "enable regex mode"    },
    { name = "case",  type = "boolean",               desc = "case-sensitive"       },
}

---@param line string
---@return string|nil file, integer|nil lnum, integer|nil col, string[]? chunks
local function parse_rg_json(line)
    local ok, decoded = pcall(vim.json.decode, line)
    if not ok or not decoded then return end
    if decoded.type ~= "match" then return end

    local data       = decoded.data
    local path       = data.path and data.path.text or nil
    local lnum       = data.line_number
    local submatches = data.submatches or {}
    local text       = data.lines.text or data.lines.bytes or ""
    local chunks     = {}
    local last_idx   = 1

    for _, m in ipairs(submatches) do
        local s = m.start + 1
        local e = m["end"]
        if s > last_idx then
            table.insert(chunks, { text:sub(last_idx, s - 1) })
        end
        table.insert(chunks, { text:sub(s, e), "Label" })
        last_idx = e + 1
    end

    if last_idx <= #text then
        table.insert(chunks, { text:sub(last_idx) })
    end

    local col = submatches[1] and (submatches[1].start + 1) or 1
    return path, lnum, col, chunks
end

---@param parsed keystone.queryflags.ParseResult
---@param opts   keystone.livegrep.opts
---@return string cmd, string[] args, string cleaned_query
local function build_rg_cmd(parsed, opts)
    local query = parsed.query
    local flags = parsed.flags

    -- merge caller-provided globs with inline glob: and in: flags
    local include_globs = vim.deepcopy(opts.include_globs or {})
    for _, g in ipairs(flags.glob or {}) do
        table.insert(include_globs, g)
    end
    for _, path in ipairs(flags["in"] or {}) do
        local p = path:gsub("^!", "\\!")
                      :gsub("^%*+", ""):gsub("%*+$", "")
                      :gsub("^%/+", ""):gsub("%/+$", "")
        if p ~= "" then
            table.insert(include_globs, "*" .. p .. "*")
            table.insert(include_globs, "**/" .. p .. "/**")
        end
    end

    local args = { "--json", "--no-heading", "--glob-case-insensitive" }

    if flags.case then
        table.insert(args, "--case-sensitive")
    else
        table.insert(args, "--smart-case")
    end

    if not flags.regex then
        table.insert(args, "--fixed-strings")
    end

    for _, g in ipairs(include_globs) do
        table.insert(args, "-g")
        table.insert(args, g)
    end

    for _, g in ipairs(opts.exclude_globs or {}) do
        table.insert(args, "-g")
        table.insert(args, "!" .. g)
    end

    table.insert(args, "--")
    table.insert(args, query)
    table.insert(args, ".")

    return "rg", args, query
end

---@param ms    number
---@param title string
---@return fun(msg:string)
local function create_error_notifier(ms, title)
    local pending = {}
    local flush = throttle.trailing_fixed_wrap(ms, function()
        if vim.tbl_isempty(pending) then return end
        local lines = {}
        for i, msg in ipairs(pending) do lines[#lines + 1] = ("%d. %s"):format(i, msg) end
        vim.notify(
            table.concat(lines, "\n"),
            vim.log.levels.ERROR,
            { title = (title .. " (%d)"):format(#pending) }
        )
        pending = {}
    end)
    return function(msg)
        pending[#pending + 1] = tostring(msg)
        flush()
    end
end

---@param parsed     keystone.queryflags.ParseResult
---@param grep_opts  keystone.livegrep.opts
---@param fetch_opts keystone.Picker.FetcherOpts
---@param on_error   fun(msg:string)
---@param callback   fun(items:table[]?)
---@return fun()? cancel
local function async_grep(parsed, grep_opts, fetch_opts, on_error, callback)
    local cmd, args, query = build_rg_cmd(parsed, grep_opts)
    if query == "" then
        callback()
        return
    end

    local max_results = grep_opts.max_results or 10000
    local stop_read   = false
    local items       = {}
    local count       = 0
    local process

    local buffered_feed = strutils.create_line_buffered_feed(function(lines)
        for _, line in ipairs(lines) do
            if stop_read then return end
            local file, lnum, col, chunks = parse_rg_json(line)
            if chunks then
                local abs_path = vim.fs.joinpath(grep_opts.cwd, file or "")
                local rel_path = fsutils.get_relative_path(abs_path)
                local location = fsutils.smart_crop_path(
                    string.format("%s:%s", rel_path, lnum),
                    fetch_opts.list_width
                )
                ---@type keystone.Picker.Item
                table.insert(items, {
                    label_chunks = chunks,
                    virt_lines   = { { { location, "Special" } } },
                    data         = { filepath = abs_path, lnum = tonumber(lnum), col = tonumber(col) },
                })
                count = count + 1
                if count >= max_results then
                    process:kill({ stop_read = true })
                    stop_read = true
                    break
                end
            end
        end
    end)

    process = Process:new(cmd, {
        cwd       = grep_opts.cwd,
        args      = args,
        on_output = function(data, is_stderr)
            if stop_read or not data then return end
            if is_stderr then on_error(data) return end
            buffered_feed(data)
        end,
        on_exit = function()
            vim.schedule(function() callback(items) end)
        end,
    })

    local ok, err = process:start()
    if not ok then
        callback({})
        on_error(err or "failed to launch ripgrep")
    end

    return function()
        if process then process:kill({ stop_read = true }) end
    end
end

---@param opts keystone.livegrep.opts?
function M.open(opts)
    opts = opts or {}
    local cwd           = opts.cwd or vim.fn.getcwd()
    local error_notifier = create_error_notifier(1000, "rg errors")

    picker.open({
        prompt          = "Live Grep",
        flags           = FLAGS,
        enable_preview  = true,
        enable_list_sep = true,
        history_provider = opts.history_provider or pickertools.make_history_provider("grep"),
        finder = function(_, fetch_opts, callback)
            local parsed = fetch_opts.parsed
                or require("keystone.pick.base.queryflags").parse(FLAGS, "")
            return async_grep(parsed, {
                cwd           = cwd,
                include_globs = opts.include_globs or {},
                exclude_globs = opts.exclude_globs or {},
                max_results   = opts.max_results or 10000,
            }, fetch_opts, error_notifier, callback)
        end,
    }, function(data)
        if data then
            uitools.smart_open_file(data.filepath, data.lnum, data.col - 1)
        end
    end)
end

return M
