local M           = {}

local uitool      = require("keystone.util.uitool")
local strutil = require("keystone.util.strutil")
local fsutil  = require("keystone.util.fsutil")
local throttle    = require("keystone.util.throttle")
local spawn       = require("keystone.util.spawn")

---@class keystone.livegrep.opts
---@field max_results number?

---@class keystone.livegrep.grep_opts
---@field cwd         string
---@field max_results number?

---@type keystone.queryflags.FlagDef[]
local FLAGS       = {
    { name = "cwd",    type = "value",                              desc = "search root directory" },
    { name = "glob",   type = "value",   multi = true,              desc = "raw glob pattern"   },
    { name = "file",   type = "value",   multi = true,              desc = "filter by filename"  },
    { name = "dir",    type = "value",   multi = true,              desc = "filter by directory" },
    { name = "regex",  type = "boolean", desc = "enable regex mode" },
    { name = "case",   type = "boolean", desc = "case-sensitive"    },
    { name = "follow", type = "boolean", desc = "follow symlinks"   },
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
---@return string cmd, string[] args, string cleaned_query
local function build_rg_cmd(parsed)
    local query = parsed.query
    local flags = parsed.flags

    local include_globs = {}

    for _, g in ipairs(flags.glob or {}) do
        table.insert(include_globs, g)
    end

    for _, val in ipairs(flags.file or {}) do
        local p = val:gsub("[/*]", "")
        if p ~= "" then
            table.insert(include_globs, "*" .. p .. "*")
        end
    end

    for _, val in ipairs(flags.dir or {}) do
        local p = val:gsub("%*", ""):gsub("^/+", ""):gsub("/+$", "")
        if p ~= "" then
            table.insert(include_globs, "**/*" .. p .. "*/**")
        end
    end

    local args = { "--json", "--no-heading", "--glob-case-insensitive" }

    if flags.follow then
        table.insert(args, "--follow")
    end

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

    table.insert(args, "--")
    table.insert(args, query)
    table.insert(args, ".")

    return "rg", args, query
end

---@param parsed     keystone.queryflags.ParseResult
---@param grep_opts  keystone.livegrep.grep_opts
---@param fetch_opts keystone.Picker.FetcherOpts
---@param callback   fun(items:table[]?)
---@return fun()? cancel
local function async_grep(parsed, grep_opts, fetch_opts, callback)
    local cmd, args, query = build_rg_cmd(parsed)
    if query == "" then
        callback()
        return
    end

    local max_results = grep_opts.max_results or 10000
    local stop_read   = false
    local items       = {}
    local count       = 0
    local sys_obj

    local function on_error(msg)
        ---@type keystone.Picker.Item
        table.insert(items, {
            label_chunks = { { "ERROR: ", "Error" }, { msg } },
            data         = {},
        })
    end

    local buffered_feed = strutil.create_line_buffered_feed(function(lines)
        for _, line in ipairs(lines) do
            if stop_read then return end
            local file, lnum, col, chunks = parse_rg_json(line)
            if chunks then
                local abs_path = vim.fs.joinpath(grep_opts.cwd, file or "")
                local rel_path = fsutil.get_relative_path(abs_path, grep_opts.cwd)
                local location = fsutil.smart_crop_path(
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
                    stop_read = true
                    if sys_obj then sys_obj.kill() end
                    break
                end
            end
        end
    end)

    local ok, err       = pcall(function()
        sys_obj = spawn(
            { cmd, unpack(args) },
            {
                cwd    = grep_opts.cwd,
                stdout = function(data)
                    if stop_read then return end
                    buffered_feed(data)
                end,
                stderr = function(data)
                    on_error(data)
                end,
            },
            function() callback(items) end
        )
    end)

    if not ok then
        callback({})
        on_error(err or "failed to launch ripgrep")
        return
    end

    return function()
        stop_read = true
        if sys_obj then sys_obj.kill() end
    end
end

---@param opts keystone.livegrep.opts?
---@return keystone.PickerSpec
function M.spec(opts)
    opts = opts or {}

    return {
        prompt          = "Live Grep",
        flags           = FLAGS,
        enable_preview  = true,
        enable_list_sep = true,
        finder           = function(query, flags, fetch_opts, callback, _)
            local parsed     = { query = query, flags = flags }
            local target_cwd = flags.cwd and vim.fn.expand(flags.cwd) or vim.fn.getcwd()
            return async_grep(parsed, {
                cwd         = target_cwd,
                max_results = opts.max_results or 10000,
            }, fetch_opts, callback)
        end,
        on_confirm = function(data)
            if data and data.filepath and data.lnum and data.col then
                uitool.smart_open_file(data.filepath, data.lnum, data.col - 1)
            end
        end,
    }
end

return M
