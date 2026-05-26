local M = {}

local ksconfig = require('keystone.pick').config
local Process = require("keystone.utils.Process")
local uitools = require("keystone.utils.uitools")
local strutils = require("keystone.utils.strutils")
local fsutils = require("keystone.utils.fsutils")
local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")
local icons = require("keystone.icons")

---@class keystone.filepicker.Opts
---@field prompt string?
---@field cwd string The root directory for the search
---@field include_globs string[]? List of glob patterns to include (filtered in Lua)
---@field exclude_globs string[]? List of glob patterns for fd to ignore
---@field max_results number?
---@field history_provider keystone.Picker.QueryHistoryProvider?

---@class keystone.filepicker.SearchOpts
---@field cwd string The root directory for the search
---@field include_globs string[]? List of glob patterns to include (filtered in Lua)
---@field exclude_globs string[]? List of glob patterns for fd to ignore
---@field max_results number?
---@field use_regex boolean?
---@field case_sensitive boolean?

---@type keystone.queryflags.FlagDef[]
local FLAGS = {
    { name = "dir",   type = "value",   multi = true, desc = "filter by directory" },
    { name = "regex", type = "boolean",               desc = "enable regex mode"   },
    { name = "case",  type = "boolean",               desc = "case-sensitive"      },
}

---@param filepath  string
---@return string? filename, string? extension
local function extract_filename_ext(filepath)
    local name = filepath:match("^.+/(.+)$")
    local ext = name and name:match("^.*%.([^%.]+)$") or nil
    return name, ext
end

---@param filename string
---@param query string
---@param use_regex boolean?
---@param case_sensitive boolean?
---@return {score:number, chunks:table[]}?
local function do_match(filename, query, use_regex, case_sensitive)
    if use_regex then
        local pattern = case_sensitive and query or ("\\c" .. query)
        local ok, re = pcall(vim.regex, pattern)
        if not ok then return nil end
        if not re:match_str(filename) then return nil end
        return { score = 0, chunks = { { filename } } }
    else
        return pickertools.match_label(filename, query)
    end
end

---@param query string User input
---@param opts keystone.filepicker.SearchOpts
---@param fetch_opts keystone.Picker.FetcherOpts
---@param callback fun(items:keystone.Picker.Item[]?)
local function async_lua_search(query, opts, fetch_opts, callback)
    assert(query ~= "")
    local count = 0
    local max_results = opts.max_results or 10000
    local items = {}

    local exclude_globs = opts.exclude_globs or {}
    -- ignore hidden
    table.insert(exclude_globs, ".*")
    table.insert(exclude_globs, "**/.*")

    local include_regex_list = opts.include_globs and strutils.compile_globs(opts.include_globs) or nil
    local exclude_regex_list = strutils.compile_globs(exclude_globs)

    local cancel_fn
    cancel_fn = fsutils.async_walk_dir(
        opts.cwd,
        {
            include_regex_list = include_regex_list,
            exclude_regex_list = exclude_regex_list,
            on_dir_enter = function(path)
                vim.cmd("redraw")
            end,
            on_file = function(filepath, filename, relative_path)
                local res = do_match(filename, query, opts.use_regex, opts.case_sensitive)
                if not res then return end
                if count >= max_results then
                    cancel_fn()
                    return
                end
                local filedir = relative_path:sub(1, #relative_path - #filename)
                local icon, icon_hl = icons.get_icon(filename)
                local chunks = { { icon, icon_hl }, { " " }, { filedir } }
                vim.list_extend(chunks, res.chunks)
                table.insert(items, {
                    label_chunks = chunks,
                    score = res.score,
                    data = {
                        filepath = filepath
                    },
                })
                count = count + 1
            end,
            on_done = function()
                vim.schedule(function()
                    callback(items)
                    callback(nil)
                end)
            end
        })
    return cancel_fn
end

---@param opts keystone.filepicker.Opts?
function M.open(opts)
    opts = opts or {}
    return picker.open({
        prompt = opts.prompt or "Files",
        flags  = FLAGS,
        enable_preview = true,
        history_provider = opts.history_provider or pickertools.make_history_provider("files"),
        finder = function(_, fetch_opts, callback)
            local parsed = fetch_opts.parsed
                or require("keystone.pick.base.queryflags").parse(FLAGS, "")
            local clean_query = parsed.query
            local flags = parsed.flags

            if not clean_query or clean_query == "" then
                callback()
                return
            end

            -- dir: directory filter — strip stars and surrounding slashes
            local include_globs = vim.deepcopy(opts.include_globs or {})
            for _, val in ipairs(flags.dir or {}) do
                local p = val:gsub("%*", ""):gsub("^/+", ""):gsub("/+$", "")
                if p ~= "" then
                    table.insert(include_globs, "**/" .. p .. "/**")
                end
            end

            ---@type keystone.filepicker.SearchOpts
            local search_opts = {
                cwd            = opts.cwd or vim.fn.getcwd(),
                include_globs  = include_globs,
                exclude_globs  = opts.exclude_globs,
                max_results    = opts.max_results or 10000,
                use_regex      = flags.regex,
                case_sensitive = flags.case,
            }
            return async_lua_search(clean_query, search_opts, fetch_opts, callback)
        end,

    }, function(data)
        if data then
            uitools.smart_open_file(data.filepath)
        end
    end)
end

return M
