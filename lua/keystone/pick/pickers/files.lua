local M           = {}

local ui          = require("keystone.tk.ui")
local strutil     = require("keystone.tk.strutil")
local fsutil      = require("keystone.tk.fsutil")
local pickertools = require("keystone.pick.base.pickertools")
local icons       = require("keystone.icons")

---@class keystone.filepicker.Opts
---@field prompt string?
---@field cwd string?
---@field max_results number?

---@alias keystone.filepicker.Mode "fuzzy"|"fixed"|"glob"

---@class keystone.filepicker.SearchOpts
---@field cwd string The root directory for the search
---@field mode keystone.filepicker.Mode? how the query matches a file (default "fuzzy")
---@field max_results number?
---@field case_sensitive boolean?
---@field follow_symlinks boolean?
---@field show_hidden boolean?

---@type keystone.queryflags.FlagDef[]
local FLAGS       = {
    { name = "dir",    type = "value",   complete = "dir", desc = "override search root directory"    },
    { name = "match",  type = "value",   values = { "fuzzy", "fixed", "glob" }, desc = "match: fuzzy (default) | fixed | glob" },
    { name = "case",   type = "value",   values = { "smart", "on", "off" }, desc = "case: smart (default) | on | off" },
    { name = "follow", type = "boolean", desc = "follow symlinks"                   },
    { name = "hidden", type = "boolean", desc = "include hidden (dotfiles)"         },
}

--- Resolve a `case` flag value into a case-sensitivity decision.
---
--- `mode` is the user-facing flag value: "on" (always sensitive), "off" (always
--- insensitive) or "smart"/nil (the default): sensitive only when `query` itself
--- contains an uppercase character.
---@param mode string?    "on"|"off"|"smart"|nil
---@param query string
---@return boolean case_sensitive
local function resolve_case(mode, query)
    if mode == "on" then return true end
    if mode == "off" then return false end
    return query:match("%u") ~= nil
end

--- Fuzzy-match a filename against the query, then apply the case gate on top.
--- The matcher itself is case-insensitive; when `case_sensitive` is set the
--- subsequence is re-checked with case and re-highlighted on a hit.
---@param filename string
---@param query string
---@param case_sensitive boolean?
---@return {score:number, chunks:table[]}?
local function fuzzy_match(filename, query, case_sensitive)
    local res = pickertools.match_label(filename, query)
    if not res then return nil end
    if case_sensitive then
        local pos = pickertools.case_subseq(filename, query)
        if not pos then return nil end
        res = { score = res.score, chunks = pickertools.highlight_chunks(filename, pos) }
    end
    return res
end

--- Literal (fixed-string) substring match, highlighting the matched run.
--- Matches case-insensitively unless `case_sensitive`; earlier matches score
--- higher so they sort ahead.
---@param filename string
---@param query string
---@param case_sensitive boolean?
---@return {score:number, chunks:table[]}?
local function fixed_match(filename, query, case_sensitive)
    if query == "" then
        return { score = 0, chunks = pickertools.highlight_chunks(filename) }
    end
    local haystack = case_sensitive and filename or filename:lower()
    local needle   = case_sensitive and query or query:lower()
    local byte_s   = haystack:find(needle, 1, true)
    if not byte_s then return nil end

    -- Convert the matched byte span into 1-based char positions for highlighting.
    local char_s    = vim.fn.charidx(filename, byte_s - 1)
    local qn        = vim.fn.strchars(query)
    local positions = {}
    for k = 0, qn - 1 do positions[#positions + 1] = char_s + 1 + k end
    return { score = -byte_s, chunks = pickertools.highlight_chunks(filename, positions) }
end

--- Match a file against the query under the selected `mode`:
---   * "fuzzy" (default) — fuzzy subsequence over the basename
---   * "fixed"           — literal substring over the basename
---   * "glob"            — rg-style glob over the relative path (unhighlighted)
--- The returned chunks always describe the basename, so the result row renders
--- identically regardless of mode.
---@param filename string
---@param relpath string
---@param query string
---@param mode keystone.filepicker.Mode?
---@param case_sensitive boolean?
---@return {score:number, chunks:table[]}?
local function do_match(filename, relpath, query, mode, case_sensitive)
    if mode == "glob" then
        if not pickertools.match_glob(query, relpath, not case_sensitive) then return nil end
        return { score = 0, chunks = pickertools.highlight_chunks(filename) }
    elseif mode == "fixed" then
        return fixed_match(filename, query, case_sensitive)
    end
    return fuzzy_match(filename, query, case_sensitive)
end

--- Build a result row for a matched file: the filetype icon, its directory
--- prefix, then the filename chunks (fuzzy match highlight).
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

---@param query string User input
---@param opts keystone.filepicker.SearchOpts
---@param fetch_opts keystone.Picker.FetcherOpts
---@param callback fun(items:keystone.Picker.Item[]?)
local function async_lua_search(query, opts, fetch_opts, callback)
    local count              = 0
    local max_results        = opts.max_results or 10000
    local items              = {}
    local mode               = opts.mode or "fuzzy"

    local base_excludes      = opts.show_hidden and {} or { ".*", "**/.*" }
    local exclude_regex_list = strutil.compile_globs(base_excludes)

    local aborted = false
    local walk_cancel ---@type fun()?
    walk_cancel = fsutil.async_walk_dir(
        opts.cwd,
        {
            exclude_regex_list = exclude_regex_list,
            follow_symlinks    = opts.follow_symlinks,
            on_dir_enter       = function(_)
                vim.cmd("redraw")
            end,
            on_file            = function(filepath, filename, relative_path)
                local res = do_match(filename, relative_path, query, mode, opts.case_sensitive)
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
                callback(items)
                callback(nil)
            end
        })

    return function()
        aborted = true
        if walk_cancel then walk_cancel() end
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
            if not query or query == "" then
                callback()
                return
            end

            local target_cwd = flags.dir or opts.cwd or vim.fn.getcwd()
            target_cwd = vim.fn.expand(target_cwd)

            ---@type keystone.filepicker.SearchOpts
            local search_opts = {
                cwd             = target_cwd,
                mode            = flags.match,
                max_results     = opts.max_results,
                case_sensitive  = resolve_case(flags.case, query),
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
