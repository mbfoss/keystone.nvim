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

---@class keystone.filepicker.SearchOpts
---@field cwd string The root directory for the search
---@field include_globs string[]? List of glob patterns to include (filtered in Lua)
---@field exclude_globs string[]? List of glob patterns for fd to ignore
---@field in_globs string[]? rg-style glob patterns; file must match at least one positive glob and no `!`-negated glob
---@field max_results number?
---@field case_sensitive boolean?
---@field follow_symlinks boolean?
---@field show_hidden boolean?

---@type keystone.queryflags.FlagDef[]
local FLAGS       = {
    { name = "dir",    type = "value",   complete = "dir", desc = "override search root directory"    },
    { name = "filter", type = "value",   multi = true, desc = "glob filter: *.txt, !*.lua, **/dir/**" },
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
