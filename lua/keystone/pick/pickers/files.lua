local M           = {}

local uitool      = require("keystone.util.uitool")
local strutil     = require("keystone.util.strutil")
local fsutil      = require("keystone.util.fsutil")
local regex       = require("keystone.util.regex")
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

---@param filename string
---@param query string fuzzy query (unused when `re` is given)
---@param re keystone.util.Regex? compiled PCRE2 pattern; when set, runs regex mode
---@param case_sensitive boolean?
---@return {score:number, chunks:table[]}?
local function do_match(filename, query, re, case_sensitive)
    -- regex mode: the compiled pattern is its own engine and already bakes in
    -- case via its compile flags, so the fuzzy query and case gate don't apply.
    if re then
        if not re:test(filename) then return nil end
        return { score = 0, chunks = { { filename } } }
    end

    -- fuzzy: match case-insensitively, then apply the case gate on top. The
    -- matcher knows nothing about case; the gate is the whole case concept.
    local res = pickertools.match_label(filename, query)
    if not res then return nil end
    if case_sensitive then
        local pos = pickertools.case_subseq(filename, query)
        if not pos then return nil end
        res = { score = res.score, chunks = pickertools.highlight_chunks(filename, pos) }
    end
    return res
end

---@param query string User input
---@param opts keystone.filepicker.SearchOpts
---@param fetch_opts keystone.Picker.FetcherOpts
---@param callback fun(items:keystone.Picker.Item[]?)
local function async_lua_search(query, opts, fetch_opts, callback)
    -- Regex mode compiles the query once as a PCRE2 pattern (real ripgrep/PCRE
    -- syntax). Case is baked into the compile flags; the smart-case decision was
    -- already made by resolve_case() in the picker spec.
    local compiled_re
    if opts.use_regex then
        local err
        compiled_re, err = regex.compile(query, opts.case_sensitive and "" or "i")
        if not compiled_re then
            -- Surface the compile failure (bad pattern, missing libpcre2-8, ...)
            -- as an inline ERROR row instead of silently showing no results.
            callback({ error_item(err or "invalid regex") })
            callback(nil)
            return function() end
        end
    end

    local count              = 0
    local max_results        = opts.max_results or 10000
    local items              = {}

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

    local cancel_fn
    cancel_fn                = fsutil.async_walk_dir(
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
                local res = do_match(filename, query, compiled_re, opts.case_sensitive)
                if not res then return end
                if count >= max_results then
                    cancel_fn()
                    return
                end
                local filedir       = relative_path:sub(1, #relative_path - #filename)
                local icon, icon_hl = icons.get_icon(filename)
                local chunks        = { { icon, icon_hl }, { " " }, { filedir } }
                vim.list_extend(chunks, res.chunks)
                table.insert(items, {
                    label_chunks = chunks,
                    score        = res.score,
                    data         = { filepath = filepath },
                })
                count = count + 1
            end,
            on_done            = function()
                vim.schedule(function()
                    callback(items)
                    callback(nil)
                end)
            end
        })
    return cancel_fn
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
            if data and data.filepath then uitool.smart_open_file(data.filepath) end
        end,
    }
end

-- Exposed for tests.
M._resolve_case = resolve_case
M._do_match     = do_match

return M
