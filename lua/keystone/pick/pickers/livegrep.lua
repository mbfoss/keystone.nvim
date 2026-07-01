local M           = {}

local ui          = require("keystone.neotoolkit.ui")
local strutil     = require("keystone.neotoolkit.strutil")
local fsutil      = require("keystone.neotoolkit.fsutil")
local spawn       = require("keystone.neotoolkit.spawn")
local regex       = require("keystone.neotoolkit.regex")
local pickertools = require("keystone.pick.base.pickertools")

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

---@param text      string
---@param subs      keystone.rgutil.Submatch[]
---@param match_hl  string
---@param show_repl boolean?  -- render "old → new" diff chunks instead of a single highlighted match
---@return {[1]:string,[2]:string?}[]
local function build_chunks(text, subs, match_hl, show_repl)
    local chunks = {}
    local last   = 1
    for _, sm in ipairs(subs) do
        local s = sm.s + 1
        local e = sm.e
        if s > last then
            chunks[#chunks + 1] = { text:sub(last, s - 1) }
        end
        if show_repl and sm.repl then
            chunks[#chunks + 1] = { text:sub(s, e), "KeystoneReplaceOld" }
            if #sm.repl > 0 then
                chunks[#chunks + 1] = { sm.repl, "KeystoneReplaceNew" }
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

---@param text string
---@param subs keystone.rgutil.Submatch[]
---@return string
local function apply_subs(text, subs)
    local parts = {}
    local last  = 1
    for _, sm in ipairs(subs) do
        local s = sm.s + 1
        local e = sm.e
        parts[#parts + 1] = text:sub(last, s - 1)
        parts[#parts + 1] = sm.repl or text:sub(s, e)
        last              = e + 1
    end
    parts[#parts + 1] = text:sub(last)
    return table.concat(parts)
end

---@param items keystone.Picker.Item[]
---@return integer total_occurrences, integer file_count
local function count_matches(items)
    local files = {}
    local total = 0
    for _, item in ipairs(items) do
        local d = item.data
        if d and d.filepath and d.subs then
            files[d.filepath] = true
            total             = total + #d.subs
        end
    end
    return total, vim.tbl_count(files)
end

---@param items keystone.Picker.Item[]
local function apply_replace_all(items)
    local by_file = {}
    local order   = {}
    for _, item in ipairs(items) do
        local d = item.data
        if d and d.filepath and d.lnum and d.subs then
            if not by_file[d.filepath] then
                by_file[d.filepath] = {}
                order[#order + 1]   = d.filepath
            end
            table.insert(by_file[d.filepath], { lnum = d.lnum, subs = d.subs })
        end
    end

    for _, filepath in ipairs(order) do
        local bufnr = vim.fn.bufadd(filepath)
        vim.bo[bufnr].buflisted = true
        vim.fn.bufload(bufnr)
        for _, edit in ipairs(by_file[filepath]) do
            local lnum = edit.lnum
            if lnum >= 1 and lnum <= vim.api.nvim_buf_line_count(bufnr) then
                local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
                if line then
                    local new_line = apply_subs(line, edit.subs)
                    if new_line ~= line then
                        vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_line })
                    end
                end
            end
        end
    end
end

---@class keystone.livegrep.opts
---@field max_results number?

---@class keystone.livegrep.grep_opts
---@field cwd         string
---@field max_results number?

---@type keystone.queryflags.FlagDef[]
local FLAGS       = {
    { name = "dir",     type = "value",   complete = "dir",          desc = "search root directory"              },
    { name = "filter",  type = "value",   multi = true,              desc = "glob filter: *.txt, !*.lua, **/dir/**" },
    { name = "regex",   type = "boolean", desc = "enable regex mode"                                             },
    { name = "case",    type = "value",   values = { "smart", "on", "off" }, desc = "case: smart (default) | on | off" },
    { name = "follow",    type = "boolean", desc = "follow symlinks"                                             },
    { name = "hidden",    type = "boolean", desc = "include hidden (dotfiles)"                                   },
    { name = "no-ignore", type = "boolean", desc = "disable .gitignore / .ignore rules"                         },
    { name = "replace",   type = "value", allow_empty = true,        desc = "replacement text (enables search & replace; empty deletes matches)" },
}


--- Common rg flags shared by the disk and in-buffer searches. Excludes globs,
--- the query, and the search target (those differ per search).
---@param parsed keystone.queryflags.ParseResult
---@return string[] args
local function build_rg_base(parsed)
    local flags = parsed.flags
    local args  = { "--json", "--no-heading", "--glob-case-insensitive" }

    if flags.follow then
        table.insert(args, "--follow")
    end

    if flags.hidden then
        table.insert(args, "--hidden")
    end

    if flags["no-ignore"] then
        table.insert(args, "--no-ignore")
    end

    if flags.case == "on" then
        table.insert(args, "--case-sensitive")
    elseif flags.case == "off" then
        table.insert(args, "--ignore-case")
    else
        table.insert(args, "--smart-case")
    end

    if not flags.regex then
        table.insert(args, "--fixed-strings")
    end

    if flags.replace then
        table.insert(args, "--replace")
        table.insert(args, flags.replace)
    end

    return args
end

--- Directory search. Disk matches for files that are open in a buffer are
--- dropped by the caller (post-filter) so their in-memory versions take
--- priority — cheaper and more robust than emitting a glob per open file.
---@param parsed keystone.queryflags.ParseResult
---@return string[] cmd
local function build_rg_dir_cmd(parsed)
    local args = build_rg_base(parsed)
    table.insert(args, "--sort")
    table.insert(args, "path")
    for _, g in ipairs(parsed.flags["filter"] or {}) do
        table.insert(args, "-g")
        table.insert(args, g)
    end
    table.insert(args, "--")
    table.insert(args, parsed.query)
    table.insert(args, ".")
    return vim.list_extend({ "rg" }, args)
end

--- Split a flag-glob list ("*.lua", "!*_spec.lua") into compiled include/exclude
--- regexes. rg's own `-g` only filters disk traversal, not stdin input, so open
--- buffers are filtered in-process instead.
---@param filters string[]?
---@return vim.regex[]? include, vim.regex[]? exclude
local function compile_filter_globs(filters)
    local include, exclude = {}, {}
    for _, g in ipairs(filters or {}) do
        if g:sub(1, 1) == "!" then
            exclude[#exclude + 1] = g:sub(2)
        else
            include[#include + 1] = g
        end
    end
    return (#include > 0 and strutil.compile_globs(include) or nil),
        (#exclude > 0 and strutil.compile_globs(exclude) or nil)
end

---@class keystone.livegrep.OpenBuf
---@field bufnr   integer
---@field path    string  absolute file path
---@field relpath string  path relative to the search cwd

--- Loaded, file-backed buffers under `cwd` that pass the filter globs. These are
--- searched from their in-memory text so unsaved (and stale-on-disk) edits win.
---@param cwd     string
---@param filters string[]?
---@return keystone.livegrep.OpenBuf[]
local function collect_open_buffers(cwd, filters)
    local include_re, exclude_re = compile_filter_globs(filters)
    local out = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
            local name = vim.api.nvim_buf_get_name(bufnr)
            if name ~= "" then
                local path = vim.fn.fnamemodify(name, ":p")
                local rel  = fsutil.get_relative_path(path, cwd)
                if rel and strutil.check_path_pattern(rel, false, include_re, exclude_re) then
                    out[#out + 1] = { bufnr = bufnr, path = path, relpath = rel }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.relpath < b.relpath end)
    return out
end

--- Build a picker item from a parsed rg match at an absolute path.
---@param m          keystone.rgutil.Match
---@param abs_path   string
---@param cwd        string
---@param list_width integer
---@param show_repl  boolean?
---@param rel_path   string?  precomputed cwd-relative path (avoids recomputation)
---@return keystone.Picker.Item
local function make_item(m, abs_path, cwd, list_width, show_repl, rel_path)
    rel_path = rel_path or fsutil.get_relative_path(abs_path, cwd) or abs_path
    local location = fsutil.smart_crop_path(
        string.format("%s:%s", rel_path, m.lnum),
        list_width
    )
    return {
        label_chunks = build_chunks(m.text, m.subs, "Label", show_repl),
        virt_lines   = { { { location, "KeystonePickPath" } } },
        data         = { filepath = abs_path, lnum = m.lnum, col = m.col, subs = m.subs },
    }
end

---@param filepath string  absolute path
---@return integer? bufnr  a loaded buffer holding this exact file, if any
local function loaded_buf_for(filepath)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr)
            and vim.api.nvim_buf_get_name(bufnr) == filepath then
            return bufnr
        end
    end
end

--- Preview the live buffer when the file is open, so the preview matches the
--- (possibly modified or stale-on-disk) text the result list was built from.
--- Falls back to the on-disk previewer for files with no open buffer.
---@type keystone.Picker.AsyncPreviewLoader
local function buffer_preview(data, opts, callback)
    local filepath = data.filepath
    if filepath and filepath ~= "" then
        local bufnr = loaded_buf_for(filepath)
        if bufnr then
            callback({
                bufnr = bufnr,
                pos   = data.lnum and { data.lnum, data.col or 0 } or nil,
            })
            return
        end
    end
    return pickertools.file_preview(data, opts, callback)
end

--------------------------------------------------------------------------------
-- In-process buffer search (PCRE2). Open buffers are searched in Lua instead of
-- spawning one rg per buffer, so thousands of open buffers don't fan out into
-- thousands of subprocesses. The directory search still uses rg.
--------------------------------------------------------------------------------

-- PCRE2 metacharacters escaped when the query is a literal (--fixed-strings).
local _PCRE_SPECIAL = {}
for ch in ("\\^$.|?*+()[]{}"):gmatch(".") do _PCRE_SPECIAL[ch] = true end

---@param s string
---@return string  s with every PCRE2 metacharacter backslash-escaped
local function escape_pcre(s)
    return (s:gsub(".", function(c)
        if _PCRE_SPECIAL[c] then return "\\" .. c end
    end))
end

--- Compile the query into a PCRE2 matcher mirroring the rg flags: literal unless
--- `regex`, and case sensitivity from `case` (smart-case = insensitive unless the
--- query has an uppercase letter).
---@param parsed keystone.queryflags.ParseResult
---@return keystone.neotoolkit.Regex? re, string? err
local function build_buf_regex(parsed)
    local flags   = parsed.flags
    local pattern = flags.regex and parsed.query or escape_pcre(parsed.query)

    local re_flags
    if flags.case == "on" then
        re_flags = ""
    elseif flags.case == "off" then
        re_flags = "i"
    else -- smart-case
        re_flags = parsed.query:find("%u") and "" or "i"
    end

    return regex.compile(pattern, re_flags)
end

--- Resolve an rg replacement reference ($0, $1.., ${n}, ${name}) to its text.
---@param name  string  the captured reference name (numeric or group name)
---@param whole string  the whole-match text
---@param caps  (string|nil)[]  capture-group substrings (1-based)
---@param re    keystone.neotoolkit.Regex
---@return string
local function resolve_group(name, whole, caps, re)
    local num = tonumber(name) or re:group_index(name)
    if not num then return "" end
    if num == 0 then return whole end
    return caps[num] or ""
end

--- Expand an rg-style replacement template for one match: `$0` is the whole
--- match, `$1`/`${1}`/`${name}` are groups, and `$$` is a literal `$`.
---@param template string
---@param whole    string
---@param caps     (string|nil)[]
---@param re       keystone.neotoolkit.Regex
---@return string
local function expand_repl(template, whole, caps, re)
    local out, i, n = {}, 1, #template
    while i <= n do
        if template:sub(i, i) ~= "$" then
            out[#out + 1] = template:sub(i, i)
            i = i + 1
        else
            local nxt = template:sub(i + 1, i + 1)
            if nxt == "$" then
                out[#out + 1] = "$"
                i = i + 2
            elseif nxt == "{" then
                local close = template:find("}", i + 2, true)
                if close then
                    out[#out + 1] = resolve_group(template:sub(i + 2, close - 1), whole, caps, re)
                    i = close + 1
                else
                    out[#out + 1] = "$"
                    i = i + 1
                end
            else
                local ref = template:match("^([%w_]+)", i + 1)
                if ref then
                    out[#out + 1] = resolve_group(ref, whole, caps, re)
                    i = i + 1 + #ref
                else
                    out[#out + 1] = "$"
                    i = i + 1
                end
            end
        end
    end
    return table.concat(out)
end

--- Search one open buffer's in-memory lines, appending picker items to `out`.
---@param re         keystone.neotoolkit.Regex
---@param repl       string?  replacement template, or nil when not replacing
---@param b          keystone.livegrep.OpenBuf
---@param cwd        string
---@param list_width integer
---@param show_repl  boolean?
---@param out        keystone.Picker.Item[]
---@param remaining  integer  cap on the number of matching lines to add
---@return integer added
local function search_buffer(re, repl, b, cwd, list_width, show_repl, out, remaining)
    local lines = vim.api.nvim_buf_get_lines(b.bufnr, 0, -1, false)
    local added = 0
    for lnum, line in ipairs(lines) do
        if added >= remaining then break end
        local subs = {} ---@type keystone.rgutil.Submatch[]
        local init, len = 1, #line
        while init <= len + 1 do
            local s, e, caps = re:find(line, init)
            if not s or not e then break end
            -- find returns 1-based inclusive [s, e]; e doubles as the 0-based
            -- exclusive end, matching rg's submatch offsets.
            subs[#subs + 1] = {
                s    = s - 1,
                e    = e,
                repl = repl and expand_repl(repl, line:sub(s, e), caps or {}, re) or nil,
            }
            init = (e >= s) and (e + 1) or (s + 1) -- guard against empty matches
        end
        if #subs > 0 then
            ---@type keystone.rgutil.Match
            local m = { path = b.path, lnum = lnum, col = subs[1].s + 1, text = line, subs = subs }
            out[#out + 1] = make_item(m, b.path, cwd, list_width, show_repl, b.relpath)
            added = added + 1
        end
    end
    return added
end

---@param parsed     keystone.queryflags.ParseResult
---@param grep_opts  keystone.livegrep.grep_opts
---@param fetch_opts keystone.Picker.FetcherOpts
---@param callback   fun(items:table[]?)
---@return fun()? cancel
local function async_grep(parsed, grep_opts, fetch_opts, callback)
    if parsed.query == "" then
        callback()
        return
    end

    local show_repl   = parsed.flags.replace ~= nil
    local max_results = grep_opts.max_results or 10000
    local cwd         = grep_opts.cwd
    local list_width  = fetch_opts.list_width

    -- Open buffers take priority: search their in-memory text, then drop the
    -- on-disk matches for those same files so stale disk content never wins.
    local bufs = collect_open_buffers(cwd, parsed.flags["filter"])
    local open_relpaths = {} ---@type table<string, true>
    for _, b in ipairs(bufs) do
        open_relpaths[b.relpath] = true
    end

    local cancelled  = false
    local dir_items  = {} ---@type keystone.Picker.Item[]
    local dir_handle ---@type keystone.neotoolkit.SpawnHandle?

    ----------------------------------------------------------------------------
    -- In-buffer searches: in-process via PCRE2 (one compiled matcher reused for
    -- every buffer), so thousands of open buffers don't spawn thousands of rg
    -- jobs. This runs synchronously; buffer matches are ready before the dir job.
    ----------------------------------------------------------------------------
    local buf_items = {} ---@type keystone.Picker.Item[]
    local re = build_buf_regex(parsed)
    if re then
        local remaining = max_results
        for _, b in ipairs(bufs) do
            if remaining <= 0 then break end
            local ok, added = pcall(
                search_buffer, re, parsed.flags.replace, b, cwd, list_width, show_repl,
                buf_items, remaining
            )
            if ok then remaining = remaining - added end
        end
    end

    -- Fired when the directory job settles; buffer matches lead the merged list.
    local function finish()
        if cancelled then return end
        local merged = {}
        vim.list_extend(merged, buf_items)
        vim.list_extend(merged, dir_items)
        for i = #merged, max_results + 1, -1 do
            merged[i] = nil
        end
        callback(merged)
    end

    ----------------------------------------------------------------------------
    -- Directory search (rg over the filesystem, open buffers excluded).
    ----------------------------------------------------------------------------
    local stop_read = false
    local count     = 0

    local function on_error(msg)
        ---@type keystone.Picker.Item
        table.insert(dir_items, {
            label_chunks = { { "ERROR: ", "Error" }, { msg } },
            data         = {},
        })
    end

    local buffered_feed = strutil.create_line_buffered_feed(function(lines)
        for _, line in ipairs(lines) do
            if stop_read then return end
            local m = parse_match(line)
            if m then
                local abs_path = vim.fs.joinpath(cwd, m.path)
                local rel_path = fsutil.get_relative_path(abs_path, cwd)
                -- Skip files already covered by the in-buffer search.
                if not (rel_path and open_relpaths[rel_path]) then
                    dir_items[#dir_items + 1] =
                        make_item(m, abs_path, cwd, list_width, show_repl, rel_path)
                    count = count + 1
                    if count >= max_results then
                        stop_read = true
                        if dir_handle then dir_handle.kill() end
                        break
                    end
                end
            end
        end
    end)

    local ok, err = pcall(function()
        dir_handle = spawn(
            build_rg_dir_cmd(parsed),
            {
                cwd    = cwd,
                stdout = function(data)
                    if not stop_read then buffered_feed(data) end
                end,
                stderr = function(data)
                    on_error(data)
                end,
            },
            function() finish() end
        )
    end)

    if not ok then
        on_error(err or "failed to launch ripgrep")
        vim.schedule(finish)
    end

    return function()
        cancelled = true
        if dir_handle then dir_handle.kill() end
    end
end

---@param opts keystone.livegrep.opts?
---@return keystone.PickerSpec
function M.spec(opts)
    opts = opts or {}

    local _last_items    = {} ---@type keystone.Picker.Item[]
    local _replace_value ---@type string?

    return {
        prompt          = "Live Grep",
        flags           = FLAGS,
        enable_preview  = true,
        previewer       = buffer_preview,
        enable_list_sep = true,
        finder           = function(query, flags, fetch_opts, callback, _)
            local parsed     = { query = query, flags = flags }
            local target_cwd = flags.dir and vim.fn.expand(flags.dir) or vim.fn.getcwd()
            _replace_value   = flags.replace
            return async_grep(parsed, {
                cwd         = target_cwd,
                max_results = opts.max_results or 10000,
            }, fetch_opts, function(items)
                _last_items = items or {}
                callback(items)
            end)
        end,
        on_confirm = function(data)
            if not data then return end
            if _replace_value then
                local total, file_count = count_matches(_last_items)
                if total == 0 then return end
                ui.confirm_action(
                    string.format("Replace %d occurrence(s) across %d file(s)?", total, file_count),
                    false,
                    function(confirmed)
                        if not confirmed then return end
                        apply_replace_all(_last_items)
                        vim.notify(
                            string.format(
                                "Replaced %d occurrence(s) in %d file(s) (buffers modified, not saved)",
                                total, file_count
                            ),
                            vim.log.levels.INFO
                        )
                    end
                )
            else
                if data.filepath and data.lnum and data.col then
                    ui.smart_open_file(data.filepath, data.lnum, data.col - 1)
                end
            end
        end,
    }
end

return M
