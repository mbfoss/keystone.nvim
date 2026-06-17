local M           = {}

local uitool      = require("keystone.util.uitool")
local strutil     = require("keystone.util.strutil")
local fsutil      = require("keystone.util.fsutil")
local spawn       = require("keystone.util.spawn")

---@class keystone.rgutil.Submatch
---@field s    integer  -- 0-indexed byte start in the line
---@field e    integer  -- 0-indexed byte end (exclusive) in the line
---@field repl string?  -- rg-computed replacement text (nil unless --replace was used)

---@class keystone.rgutil.Match
---@field path string
---@field lnum integer
---@field col  integer  -- 1-indexed byte column of the first submatch
---@field text string
---@field subs keystone.rgutil.Submatch[]

---@param line string
---@return keystone.rgutil.Match?
local function parse_match(line)
    local ok, decoded = pcall(vim.json.decode, line)
    if not ok or not decoded or decoded.type ~= "match" then return end

    local data = decoded.data
    local path = data.path and data.path.text
    if not path then return end

    local text = data.lines.text or data.lines.bytes or ""
    text       = text:gsub("\r?\n$", "")

    local subs = {}
    for _, m in ipairs(data.submatches or {}) do
        subs[#subs + 1] = {
            s    = m.start,
            e    = m["end"],
            repl = m.replacement and m.replacement.text or nil,
        }
    end

    local col = (subs[1] and subs[1].s + 1) or 1
    return { path = path, lnum = data.line_number, col = col, text = text, subs = subs }
end

---@param text     string
---@param subs     keystone.rgutil.Submatch[]
---@param match_hl string
---@param use_repl boolean?
---@return {[1]:string,[2]:string?}[]
local function build_chunks(text, subs, match_hl, use_repl)
    local chunks = {}
    local last   = 1
    for _, sm in ipairs(subs) do
        local s = sm.s + 1
        local e = sm.e
        if s > last then
            chunks[#chunks + 1] = { text:sub(last, s - 1) }
        end
        if use_repl then
            if sm.repl and #sm.repl > 0 then
                chunks[#chunks + 1] = { sm.repl, match_hl }
            end
        else
            chunks[#chunks + 1] = { text:sub(s, e), match_hl }
        end
        last = e + 1
    end
    if last <= #text then
        chunks[#chunks + 1] = { text:sub(last) }
    end
    return chunks
end

---@class keystone.livegrep.opts
---@field max_results number?

---@class keystone.livegrep.grep_opts
---@field cwd         string
---@field max_results number?

---@type keystone.queryflags.FlagDef[]
local FLAGS       = {
    { name = "cwd",    type = "value",                              desc = "search root directory"              },
    { name = "in",     type = "value",   multi = true,              desc = "glob filter: *.txt, **/dir/**"      },
    { name = "regex",  type = "boolean", desc = "enable regex mode"                                             },
    { name = "case",   type = "boolean", desc = "case-sensitive"                                                },
    { name = "follow", type = "boolean", desc = "follow symlinks"                                               },
}


---@param parsed keystone.queryflags.ParseResult
---@return string cmd, string[] args, string cleaned_query
local function build_rg_cmd(parsed)
    local query = parsed.query
    local flags = parsed.flags

    local include_globs = vim.list_extend({}, flags["in"] or {})

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
            local m = parse_match(line)
            if m then
                local abs_path = vim.fs.joinpath(grep_opts.cwd, m.path)
                local rel_path = fsutil.get_relative_path(abs_path, grep_opts.cwd)
                local location = fsutil.smart_crop_path(
                    string.format("%s:%s", rel_path, m.lnum),
                    fetch_opts.list_width
                )
                ---@type keystone.Picker.Item
                table.insert(items, {
                    label_chunks = build_chunks(m.text, m.subs, "Label", false),
                    virt_lines   = { { { location, "KeystonePickPath" } } },
                    data         = { filepath = abs_path, lnum = m.lnum, col = m.col },
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
