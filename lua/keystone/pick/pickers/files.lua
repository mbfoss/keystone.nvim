local M           = {}

local ui          = require("keystone.tk.ui")
local strutil     = require("keystone.tk.strutil")
local fsutil      = require("keystone.tk.fsutil")
local spawn       = require("keystone.tk.spawn")
local pickertools = require("keystone.pick.base.pickertools")
local icons       = require("keystone.icons")

---@class keystone.filepicker.Opts
---@field prompt string?
---@field cwd string?
---@field max_results number?

---@class keystone.filepicker.SearchOpts
---@field cwd string The root directory for the search
---@field include_globs string[]? List of glob patterns to include (filtered in Lua)
---@field exclude_globs string[]? List of glob patterns for fd to ignore
---@field in_globs string[]? rg-style glob patterns; file must match at least one positive glob and no `!`-negated glob
---@field max_results number?
---@field use_regex boolean?
---@field case_sensitive boolean?
---@field follow_symlinks boolean?
---@field show_hidden boolean?

---@type keystone.queryflags.FlagDef[]
local FLAGS       = {
    { name = "dir",    type = "value",   complete = "dir", desc = "override search root directory"    },
    { name = "filter", type = "value",   multi = true, desc = "glob filter: *.txt, !*.lua, **/dir/**" },
    { name = "regex",  type = "boolean", desc = "enable regex mode"                 },
    { name = "case",   type = "value",   values = { "smart", "on", "off" }, desc = "case: smart (default) | on | off" },
    { name = "follow", type = "boolean", desc = "follow symlinks"                   },
    { name = "hidden", type = "boolean", desc = "include hidden (dotfiles)"         },
}

--- Resolve a `case` flag value into a case-sensitivity decision.
---
--- `mode` is the user-facing flag value: "on" (always sensitive), "off" (always
--- insensitive) or "smart"/nil (the default): sensitive only when `query` itself
--- contains an uppercase character. Smart-case is a literal-text heuristic, so for
--- a hand-written regex (`is_regex`) it degrades to insensitive — an uppercase
--- char there is usually a metacharacter (`\S`, `[A-Z]`), not user case intent.
---@param mode string?    "on"|"off"|"smart"|nil
---@param query string
---@param is_regex boolean?
---@return boolean case_sensitive
local function resolve_case(mode, query, is_regex)
    if mode == "on" then return true end
    if mode == "off" then return false end
    if is_regex then return false end
    return query:match("%u") ~= nil
end

--- Build a single result row that surfaces a search error inline, mirroring the
--- live grep picker's error reporting.
---@param msg string
---@return keystone.Picker.Item
local function error_item(msg)
    return {
        label_chunks = { { "ERROR: ", "Error" }, { msg } },
        score        = 0,
        data         = {},
    }
end

--- Fuzzy-match a filename against the query, then apply the case gate on top.
--- The matcher itself is case-insensitive; when `case_sensitive` is set the
--- subsequence is re-checked with case and re-highlighted on a hit. Regex mode
--- does not go through here — it is filtered by ripgrep (see run_regex_filter).
---@param filename string
---@param query string
---@param case_sensitive boolean?
---@return {score:number, chunks:table[]}?
local function do_match(filename, query, case_sensitive)
    local res = pickertools.match_label(filename, query)
    if not res then return nil end
    if case_sensitive then
        local pos = pickertools.case_subseq(filename, query)
        if not pos then return nil end
        res = { score = res.score, chunks = pickertools.highlight_chunks(filename, pos) }
    end
    return res
end

--- Build a result row for a matched file: the filetype icon, its directory
--- prefix, then the filename chunks (fuzzy or regex match highlight).
---@param filepath string
---@param filename string
---@param relative_path string
---@param name_chunks table[]
---@param score number
---@return keystone.Picker.Item
local function make_file_item(filepath, filename, relative_path, name_chunks, score)
    local filedir       = relative_path:sub(1, #relative_path - #filename)
    local icon, icon_hl = icons.get_icon(filename)
    local chunks        = { { icon, icon_hl }, { " " }, { filedir } }
    vim.list_extend(chunks, name_chunks)
    return {
        label_chunks = chunks,
        score        = score,
        data         = { filepath = filepath },
    }
end

--- Highlight the matched byte ranges of a filename, mirroring the fuzzy path's
--- match highlight group ("Todo"). `subs` are rg submatch offsets: `s` is the
--- 0-based byte start, `e` the exclusive byte end. Matches are character-aligned
--- in rg's output, so byte slicing never splits a multibyte character.
---@param text string
---@param subs {s:integer,e:integer}[]
---@return table[] chunks
local function highlight_name_chunks(text, subs)
    local chunks = {}
    local last   = 1
    for _, sm in ipairs(subs) do
        local s = sm.s + 1
        local e = sm.e
        if s > last then
            chunks[#chunks + 1] = { text:sub(last, s - 1) }
        end
        chunks[#chunks + 1] = { text:sub(s, e), "Todo" }
        last = e + 1
    end
    if last <= #text then
        chunks[#chunks + 1] = { text:sub(last) }
    end
    return chunks
end

--- ripgrep command for the regex filename filter: candidate names arrive on
--- stdin one per line, so the JSON `line_number` maps straight back to the
--- candidate index, and `submatches` give the byte offsets to highlight. Case
--- was already decided by resolve_case() in the picker spec.
---@param query string
---@param case_sensitive boolean?
---@return string[] cmd
local function build_files_rg_cmd(query, case_sensitive)
    local args = { "rg", "--json", "--line-buffered" }
    table.insert(args, case_sensitive and "--case-sensitive" or "--ignore-case")
    table.insert(args, "--")
    table.insert(args, query)
    table.insert(args, "-")
    return args
end

--- Filter collected candidates through a single ripgrep (regex mode). Each name
--- is streamed to stdin as its own line with backpressure (peak extra memory
--- ~one write). rg's `--json` reports, per match, a `line_number` (the candidate
--- index) and `submatches` (byte offsets to highlight). Delivers via
--- `callback(items)` then `callback(nil)`, mirroring the fuzzy path; a bad
--- pattern surfaces rg's stderr as an inline row.
---@param candidates {filepath:string,filename:string,relative_path:string}[]
---@param query string
---@param case_sensitive boolean?
---@param max_results integer
---@param callback fun(items:keystone.Picker.Item[]?)
---@return fun() cancel
local function run_regex_filter(candidates, query, case_sensitive, max_results, callback)
    if #candidates == 0 then
        callback({})
        callback(nil)
        return function() end
    end

    ---@type {cand:{filepath:string,filename:string,relative_path:string},subs:{s:integer,e:integer}[]}[]
    local matched   = {}
    local err_parts = {}
    local rg_handle ---@type keystone.tk.SpawnHandle?
    local stop      = false -- hit max_results: stop feeding but still deliver
    local aborted   = false -- external cancel: suppress delivery

    -- rg's stdout callback runs in libuv's fast-event context, where the icon
    -- highlight setup in make_file_item (nvim_set_hl) is banned. So only decode
    -- the JSON matches here (pure Lua) and build the rows on the main loop.
    local feed = strutil.create_line_buffered_feed(function(lines)
        for _, line in ipairs(lines) do
            if stop then return end
            local ok, decoded = pcall(vim.json.decode, line)
            if ok and decoded and decoded.type == "match" then
                local data = decoded.data
                local c = data.line_number and candidates[data.line_number]
                if c then
                    local subs = {}
                    for _, sm in ipairs(data.submatches or {}) do
                        subs[#subs + 1] = { s = sm.start, e = sm["end"] }
                    end
                    matched[#matched + 1] = { cand = c, subs = subs }
                    if #matched >= max_results then
                        stop = true
                        if rg_handle then rg_handle.kill() end
                        return
                    end
                end
            end
        end
    end)

    local ok, spawn_err = pcall(function()
        rg_handle = spawn(
            build_files_rg_cmd(query, case_sensitive),
            {
                stdin  = true,
                stdout = function(data) if not stop then feed(data) end end,
                stderr = function(data) err_parts[#err_parts + 1] = data end,
            },
            function()
                vim.schedule(function()
                    if aborted then return end
                    if #matched == 0 and #err_parts > 0 then
                        callback({ error_item((table.concat(err_parts):gsub("%s+$", ""))) })
                    else
                        local items = {}
                        for _, m in ipairs(matched) do
                            local c = m.cand
                            items[#items + 1] = make_file_item(
                                c.filepath, c.filename, c.relative_path,
                                highlight_name_chunks(c.filename, m.subs), 0)
                        end
                        callback(items)
                    end
                    callback(nil)
                end)
            end
        )
    end)

    if not ok or not rg_handle then
        callback({ error_item(tostring(spawn_err or "failed to launch ripgrep")) })
        callback(nil)
        return function() end
    end

    -- Pump one candidate per stdin write, resuming the next on the main loop.
    local function pump(i)
        if aborted then return end
        if stop or i > #candidates then
            if rg_handle then rg_handle.write(nil) end
            return
        end
        rg_handle.write(candidates[i].filename .. "\n", function()
            vim.schedule(function() pump(i + 1) end)
        end)
    end
    pump(1)

    return function()
        aborted = true
        if rg_handle then rg_handle.kill() end
    end
end

---@param query string User input
---@param opts keystone.filepicker.SearchOpts
---@param fetch_opts keystone.Picker.FetcherOpts
---@param callback fun(items:keystone.Picker.Item[]?)
local function async_lua_search(query, opts, fetch_opts, callback)
    local count              = 0
    local max_results        = opts.max_results or 10000
    local items              = {}
    local candidates         = {} ---@type {filepath:string,filename:string,relative_path:string}[]

    local base_excludes      = opts.show_hidden and {} or { ".*", "**/.*" }
    local exclude_globs      = vim.list_extend(base_excludes, opts.exclude_globs or {})
    local include_regex_list = (opts.include_globs and #opts.include_globs > 0)
        and strutil.compile_globs(opts.include_globs) or nil
    local exclude_regex_list = strutil.compile_globs(exclude_globs)

    -- Split the rg-style filter globs into positive matches and `!`-negated
    -- exclusions (e.g. `!*.lua`), mirroring ripgrep's `--glob` semantics.
    local in_globs, not_globs ---@type string[]?, string[]?
    for _, g in ipairs(opts.in_globs or {}) do
        local neg = g:match("^!(.+)$")
        if neg then
            not_globs = not_globs or {}
            not_globs[#not_globs + 1] = neg
        else
            in_globs = in_globs or {}
            in_globs[#in_globs + 1] = g
        end
    end

    local aborted = false
    local rg_cancel ---@type fun()?
    local walk_cancel ---@type fun()?
    walk_cancel = fsutil.async_walk_dir(
        opts.cwd,
        {
            include_regex_list = include_regex_list,
            exclude_regex_list = exclude_regex_list,
            follow_symlinks    = opts.follow_symlinks,
            on_dir_enter       = function(_)
                vim.cmd("redraw")
            end,
            on_file            = function(filepath, filename, relative_path)
                if in_globs then
                    local matched = false
                    for _, g in ipairs(in_globs) do
                        if pickertools.match_glob(g, relative_path, true) then matched = true; break end
                    end
                    if not matched then return end
                end
                if not_globs then
                    for _, g in ipairs(not_globs) do
                        if pickertools.match_glob(g, relative_path, true) then return end
                    end
                end

                -- Regex mode defers matching: collect candidates and filter them
                -- through one rg pass on walk completion. A newline in a name
                -- would desync the one-name-per-line stream, so skip those.
                if opts.use_regex then
                    if not filename:find("[\r\n]") then
                        candidates[#candidates + 1] = {
                            filepath = filepath, filename = filename, relative_path = relative_path,
                        }
                    end
                    return
                end

                local res = do_match(filename, query, opts.case_sensitive)
                if not res then return end
                if count >= max_results then
                    if walk_cancel then walk_cancel() end
                    return
                end
                items[#items + 1] = make_file_item(filepath, filename, relative_path, res.chunks, res.score)
                count = count + 1
            end,
            on_done            = function()
                if aborted then return end
                if opts.use_regex then
                    rg_cancel = run_regex_filter(candidates, query, opts.case_sensitive, max_results, callback)
                else
                    callback(items)
                    callback(nil)
                end
            end
        })

    return function()
        aborted = true
        if walk_cancel then walk_cancel() end
        if rg_cancel then rg_cancel() end
    end
end

---@param opts keystone.filepicker.Opts?
---@return keystone.PickerSpec
function M.spec(opts)
    opts = opts or {}
    return {
        prompt         = opts.prompt or "Files",
        flags          = opts.cwd and vim.tbl_filter(function(f) return f.name ~= "dir" end, FLAGS) or FLAGS,
        enable_preview = true,
        finder         = function(query, flags, fetch_opts, callback, _)
            local in_globs = flags.filter or {}
            if (not query or query == "") and #in_globs == 0 then
                callback()
                return
            end
            query = query or ""

            local target_cwd = flags.dir or opts.cwd or vim.fn.getcwd()
            target_cwd = vim.fn.expand(target_cwd)

            ---@type keystone.filepicker.SearchOpts
            local search_opts = {
                cwd             = target_cwd,
                include_globs   = nil,
                in_globs        = #in_globs > 0 and in_globs or nil,
                exclude_globs   = nil,
                max_results     = opts.max_results,
                use_regex       = flags.regex,
                case_sensitive  = resolve_case(flags.case, query, flags.regex),
                follow_symlinks = flags.follow,
                show_hidden     = flags.hidden,
            }
            return async_lua_search(query, search_opts, fetch_opts, callback)
        end,
        on_confirm     = function(data)
            if data and data.filepath then ui.smart_open_file(data.filepath) end
        end,
    }
end

-- Exposed for tests.
M._resolve_case = resolve_case
M._do_match     = do_match

return M
