local M       = {}

local uitool  = require("keystone.util.uitool")
local strutil = require("keystone.util.strutil")
local fsutil  = require("keystone.util.fsutil")
local spawn   = require("keystone.util.spawn")

---@class keystone.gitgrep.Submatch
---@field s integer  -- 0-indexed byte start in the line
---@field e integer  -- 0-indexed byte end (exclusive) in the line

-- Matches a single SGR (color) escape sequence, e.g. "\27[1;31m".
local _ANSI = "\27%[[0-9;]*m"

---Strip every SGR escape sequence from `s`.
---@param s string
---@return string
local function strip_ansi(s)
    return (s:gsub(_ANSI, ""))
end

---Parse a `git grep --color=always` match line into clean text plus the byte
---ranges that git wrapped in color codes (the actual matches).
---@param text string  -- the colored line text (path/lnum already split off)
---@return string clean, keystone.gitgrep.Submatch[] subs
local function parse_ansi(text)
    local out       = {}
    local subs      = {}
    local pos       = 1
    local clean_len = 0    -- byte length of `out` so far == 0-indexed offset
    local start             ---@type integer?

    while pos <= #text do
        local s, e = text:find(_ANSI, pos)
        if not s then
            out[#out + 1] = text:sub(pos)
            clean_len     = clean_len + (#text - pos + 1)
            break
        end
        if s > pos then
            out[#out + 1] = text:sub(pos, s - 1)
            clean_len     = clean_len + (s - pos)
        end
        local code = text:sub(s, e)
        if code == "\27[m" or code == "\27[0m" then
            if start then
                subs[#subs + 1] = { s = start, e = clean_len }
                start           = nil
            end
        elseif not start then
            start = clean_len
        end
        pos = e + 1
    end
    if start then
        subs[#subs + 1] = { s = start, e = clean_len }
    end

    return table.concat(out), subs
end

---@class keystone.gitgrep.Match
---@field path string
---@field lnum integer
---@field col  integer  -- 1-indexed byte column of the first match
---@field text string
---@field subs keystone.gitgrep.Submatch[]

---Parse one NUL-delimited record (`path\0lnum\0text`) from `git grep -z`.
---@param record string
---@return keystone.gitgrep.Match?
local function parse_record(record)
    record = record:gsub("\r$", "")
    if record == "" then return end

    local p1 = record:find("\0", 1, true)
    if not p1 then return end
    local p2 = record:find("\0", p1 + 1, true)
    if not p2 then return end

    local path        = strip_ansi(record:sub(1, p1 - 1))
    local lnum        = tonumber(strip_ansi(record:sub(p1 + 1, p2 - 1)))
    if not path or path == "" or not lnum then return end

    local text, subs = parse_ansi(record:sub(p2 + 1))
    local col        = (subs[1] and subs[1].s + 1) or 1
    return { path = path, lnum = lnum, col = col, text = text, subs = subs }
end

---@param text     string
---@param subs     keystone.gitgrep.Submatch[]
---@param match_hl string
---@return {[1]:string,[2]:string?}[]
local function build_chunks(text, subs, match_hl)
    local chunks = {}
    local last   = 1
    for _, sm in ipairs(subs) do
        local s = sm.s + 1
        local e = sm.e
        if s > last then
            chunks[#chunks + 1] = { text:sub(last, s - 1) }
        end
        chunks[#chunks + 1] = { text:sub(s, e), match_hl }
        last                = e + 1
    end
    if last <= #text then
        chunks[#chunks + 1] = { text:sub(last) }
    end
    return chunks
end

---@type keystone.queryflags.FlagDef[]
local FLAGS = {
    { name = "cwd",       type = "value",                 desc = "search root directory (inside the repo)" },
    { name = "in",        type = "value",   multi = true, desc = "limit to pathspec(s): *.lua, src/"       },
    { name = "regex",     type = "boolean",               desc = "treat query as a POSIX extended regex"   },
    { name = "case",      type = "boolean",               desc = "case-sensitive"                          },
    { name = "word",      type = "boolean",               desc = "match whole words only"                  },
    { name = "untracked", type = "boolean",               desc = "also search untracked files"             },
}

---@param query string
---@param flags table
---@return string[] args
local function build_grep_args(query, flags)
    -- Force a known match color so highlight parsing works regardless of the
    -- user's `color.grep.*` config; matches are delimited by these escapes.
    local args = {
        "-c", "color.grep.match=red",
        "grep", "-I", "-n", "-z", "--color=always",
    }

    if not flags.case then
        table.insert(args, "-i")
    end

    if flags.word then
        table.insert(args, "-w")
    end

    if flags.untracked then
        table.insert(args, "--untracked")
    end

    if flags.regex then
        table.insert(args, "-E")
    else
        table.insert(args, "-F")
    end

    table.insert(args, "-e")
    table.insert(args, query)

    table.insert(args, "--")
    for _, p in ipairs(flags["in"] or {}) do
        table.insert(args, p)
    end

    return args
end

---@param query      string
---@param flags      table
---@param cwd        string
---@param fetch_opts keystone.Picker.FetcherOpts
---@param callback   fun(items:keystone.Picker.Item[]?)
---@return fun()? cancel
local function async_grep(query, flags, cwd, fetch_opts, callback)
    if query == "" then
        callback()
        return
    end

    local args      = build_grep_args(query, flags)
    local items      = {}
    local errbuf     = {}
    local stop_read  = false
    local sys_obj

    local buffered_feed = strutil.create_line_buffered_feed(function(lines)
        for _, line in ipairs(lines) do
            if stop_read then return end
            local m = parse_record(line)
            if m then
                local abs_path = vim.fs.joinpath(cwd, m.path)
                local location = fsutil.smart_crop_path(
                    string.format("%s:%s", m.path, m.lnum),
                    fetch_opts.list_width
                )
                ---@type keystone.Picker.Item
                table.insert(items, {
                    label_chunks = build_chunks(m.text, m.subs, "Label"),
                    virt_lines   = { { { location, "KeystonePickPath" } } },
                    data         = { filepath = abs_path, lnum = m.lnum, col = m.col },
                })
            end
        end
    end)

    local ok, err = pcall(function()
        sys_obj = spawn(
            { "git", unpack(args) },
            {
                cwd    = cwd,
                stdout = function(data)
                    if stop_read then return end
                    buffered_feed(data)
                end,
                stderr = function(data) table.insert(errbuf, data) end,
            },
            function(code)
                -- git grep exits 1 when there are simply no matches.
                if code ~= 0 and code ~= 1 and #items == 0 then
                    local msg = vim.trim(table.concat(errbuf)):gsub("\n", " ")
                    table.insert(items, {
                        label_chunks = { { "ERROR: ", "Error" }, { msg ~= "" and msg or "git grep failed" } },
                        data         = {},
                    })
                end
                callback(items)
            end
        )
    end)

    if not ok then
        callback({ {
            label_chunks = { { "ERROR: ", "Error" }, { tostring(err) } },
            data         = {},
        } })
        return
    end

    return function()
        stop_read = true
        if sys_obj then sys_obj.kill() end
    end
end

---@class keystone.gitgrep.opts
---@field cwd string?

---@param opts keystone.gitgrep.opts?
---@return keystone.PickerSpec?
function M.spec(opts)
    opts = opts or {}
    local cwd = opts.cwd or vim.fn.getcwd()

    local inside = vim.system(
        { "git", "rev-parse", "--is-inside-work-tree" },
        { cwd = cwd }
    ):wait()

    if inside.code ~= 0 or vim.trim(inside.stdout or "") ~= "true" then
        vim.notify("Not inside a git work tree", vim.log.levels.ERROR)
        return nil
    end

    return {
        prompt          = "Git Grep",
        flags           = FLAGS,
        enable_preview  = true,
        enable_list_sep = true,
        finder          = function(query, flags, fetch_opts, callback, _)
            local target_cwd = flags.cwd and vim.fn.expand(flags.cwd) or cwd
            return async_grep(query, flags, target_cwd, fetch_opts, callback)
        end,
        on_confirm      = function(data)
            if data and data.filepath and data.lnum and data.col then
                uitool.smart_open_file(data.filepath, data.lnum, data.col - 1)
            end
        end,
    }
end

return M
