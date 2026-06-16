local M        = {}

local uitool  = require("keystone.util.uitool")
local strutil = require("keystone.util.strutil")
local fsutil  = require("keystone.util.fsutil")
local spawn   = require("keystone.util.spawn")
local rg_util = require("keystone.pick.pickers.shared.rg_util")

---@class keystone.searchreplace.opts
---@field from        string?  -- search pattern (prompted if omitted)
---@field to          string?  -- replacement text (prompted if omitted)
---@field max_results number?

---@type keystone.queryflags.FlagDef[]
local FLAGS    = {
    { name = "cwd",    type = "value",                              desc = "search root directory" },
    { name = "glob",   type = "value",   multi = true,             desc = "raw glob pattern"      },
    { name = "file",   type = "value",   multi = true,             desc = "filter by filename"    },
    { name = "dir",    type = "value",   multi = true,             desc = "filter by directory"   },
    { name = "regex",  type = "boolean",                           desc = "enable regex mode"     },
    { name = "case",   type = "boolean",                           desc = "case-sensitive"        },
    { name = "follow", type = "boolean",                           desc = "follow symlinks"       },
}

-- Query syntax: "<from>/<to>".  The first unquoted "/" separates the search
-- pattern from the replacement.  Both " and ' act as quotes: they protect a
-- literal "/" (and surrounding spaces) and are stripped.  Each quote style is
-- literal inside the other, so a literal quote can be embedded by wrapping it
-- in the opposite style.
--   foo/bar          search foo, replace with bar
--   foo/             search foo, delete (empty replacement)
--   foo              no "/": plain search, behaves like live grep (no replacement)
--   "a/b"/c          search "a/b" literally, replace with c
--   foo/'a/b'        search foo, replace with "a/b"
--   '"'/x            search a literal double-quote, replace with x
--   "'"/x            search a literal single-quote, replace with x
---@param query string
---@return string from, string? to  -- `to` is nil when no unquoted "/" is present
local function split_query(query)
    local from, to = {}, nil
    local buf      = from
    local quote    = nil ---@type string? active quote char (" or '), nil when unquoted
    for i = 1, #query do
        local c = query:sub(i, i)
        if quote then
            if c == quote then
                quote = nil -- close quote (dropped)
            else
                buf[#buf + 1] = c
            end
        elseif c == '"' or c == "'" then
            quote = c       -- open quote (dropped)
        elseif c == "/" and to == nil then
            to  = {}
            buf = to
        else
            buf[#buf + 1] = c
        end
    end

    if to == nil then
        return table.concat(from), nil
    end
    return table.concat(from), table.concat(to)
end

---@class keystone.searchreplace.Match
---@field filepath string
---@field relpath  string
---@field lnum     integer
---@field col      integer
---@field text     string
---@field subs     keystone.rgutil.Submatch[]

---@param pattern     string
---@param replacement string?  -- nil = grep mode (no replacement)
---@param flags       table
---@return string cmd, string[] args
local function build_rg_cmd(pattern, replacement, flags)
    local include_globs = {}
    for _, g in ipairs(flags.glob or {}) do
        include_globs[#include_globs + 1] = g
    end
    for _, val in ipairs(flags.file or {}) do
        local p = val:gsub("[/*]", "")
        if p ~= "" then include_globs[#include_globs + 1] = "*" .. p .. "*" end
    end
    for _, val in ipairs(flags.dir or {}) do
        local p = val:gsub("%*", ""):gsub("^/+", ""):gsub("/+$", "")
        if p ~= "" then include_globs[#include_globs + 1] = "**/*" .. p .. "*/**" end
    end

    local args = { "--json", "--no-heading", "--glob-case-insensitive" }

    if flags.follow then table.insert(args, "--follow") end

    if flags.case then
        table.insert(args, "--case-sensitive")
    else
        table.insert(args, "--smart-case")
    end

    if not flags.regex then table.insert(args, "--fixed-strings") end

    if replacement ~= nil then
        table.insert(args, "--replace")
        table.insert(args, replacement)
    end

    for _, g in ipairs(include_globs) do
        table.insert(args, "-g")
        table.insert(args, g)
    end

    table.insert(args, "--")
    table.insert(args, pattern)
    table.insert(args, ".")

    return "rg", args
end

-- Apply every collected replacement.  Edits use the original byte offsets and
-- rg's per-match replacement text, applied bottom-up / right-to-left so earlier
-- offsets stay valid.  Files with unsaved changes are skipped (rg read disk).
---@param matches keystone.searchreplace.Match[]
local function apply_replacements(matches)
    if not matches or #matches == 0 then
        vim.notify("No matches to replace", vim.log.levels.WARN)
        return
    end

    local by_file = {} ---@type table<string, keystone.searchreplace.Match[]>
    local order   = {}
    local total   = 0
    for _, m in ipairs(matches) do
        if not by_file[m.filepath] then
            by_file[m.filepath] = {}
            order[#order + 1]   = m.filepath
        end
        table.insert(by_file[m.filepath], m)
        total = total + #m.subs
    end

    local choice = vim.fn.confirm(
        string.format("Replace %d occurrence(s) across %d file(s)?", total, #order),
        "&Replace\n&Cancel", 2
    )
    if choice ~= 1 then return end

    local occ, changed = 0, 0
    local skipped      = {}

    for _, path in ipairs(order) do
        local bufnr = vim.fn.bufadd(path)
        vim.fn.bufload(bufnr)

        if vim.bo[bufnr].modified then
            skipped[#skipped + 1] = path
        else
            local edits = {}
            for _, m in ipairs(by_file[path]) do
                for _, sm in ipairs(m.subs) do
                    if sm.repl then
                        edits[#edits + 1] = { row = m.lnum - 1, s = sm.s, e = sm.e, repl = sm.repl }
                    end
                end
            end
            table.sort(edits, function(a, b)
                if a.row ~= b.row then return a.row > b.row end
                return a.s > b.s
            end)

            local line_count = vim.api.nvim_buf_line_count(bufnr)
            for _, ed in ipairs(edits) do
                if ed.row < line_count then
                    local repl_lines = vim.split(ed.repl, "\n", { plain = true })
                    local ok = pcall(vim.api.nvim_buf_set_text, bufnr, ed.row, ed.s, ed.row, ed.e, repl_lines)
                    if ok then occ = occ + 1 end
                end
            end

            local ok = pcall(function()
                vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent keepjumps update") end)
            end)
            if ok then changed = changed + 1 else skipped[#skipped + 1] = path end
        end
    end

    local msg = string.format("Replaced %d occurrence(s) in %d file(s)", occ, changed)
    if #skipped > 0 then
        msg = msg .. string.format("; skipped %d (unsaved/unwritable)", #skipped)
    end
    vim.notify(msg, vim.log.levels.INFO)
end

---@param opts keystone.searchreplace.opts?
---@return keystone.PickerSpec
function M.spec(opts)
    opts          = opts or {}
    local _max    = opts.max_results or 10000

    -- Latest finder run wins; `_state` feeds the confirm/apply action.
    local _run_id = 0
    local _state  = { is_replace = false, matches = {} } ---@type {is_replace:boolean, matches:keystone.searchreplace.Match[]}

    return {
        prompt          = "Search & Replace  (from/to)",
        flags           = FLAGS,
        enable_preview  = true,
        enable_list_sep = true,
        finder          = function(query, flags, fetch_opts, callback, _)
            local pattern, replacement = split_query(query)
            if pattern == "" then
                callback()
                return
            end

            local is_replace = replacement ~= nil
            local target_cwd = flags.cwd and vim.fn.expand(flags.cwd) or vim.fn.getcwd()
            local cmd, args  = build_rg_cmd(pattern, replacement, flags)

            _run_id          = _run_id + 1
            local my_id      = _run_id

            local stop_read  = false
            local count      = 0
            local items      = {}
            local matches    = {} ---@type keystone.searchreplace.Match[]
            local sys_obj

            local function on_error(msg)
                items[#items + 1] = {
                    label_chunks = { { "ERROR: ", "Error" }, { msg } },
                    data         = {},
                }
            end

            local buffered_feed = strutil.create_line_buffered_feed(function(lines)
                for _, line in ipairs(lines) do
                    if stop_read then return end
                    local m = rg_util.parse_match(line)
                    if m then
                        local abs_path = vim.fs.joinpath(target_cwd, m.path)
                        local rel_path = fsutil.get_relative_path(abs_path, target_cwd)

                        matches[#matches + 1] = {
                            filepath = abs_path,
                            relpath  = rel_path or abs_path,
                            lnum     = m.lnum,
                            col      = m.col,
                            text     = m.text,
                            subs     = m.subs,
                        }

                        local location = fsutil.smart_crop_path(
                            string.format("%s:%d", rel_path, m.lnum),
                            fetch_opts.list_width
                        )

                        -- Replace mode: a single line showing each match as
                        -- removed-then-added inline.  Grep mode: matched text.
                        local label_chunks = is_replace
                            and rg_util.build_diff_chunks(m.text, m.subs, "Removed", "Added")
                            or rg_util.build_chunks(m.text, m.subs, "Label", false)

                        ---@type keystone.Picker.Item
                        items[#items + 1] = {
                            label_chunks = label_chunks,
                            virt_lines   = { { { location, "KeystonePickPath" } } },
                            data         = { filepath = abs_path, lnum = m.lnum, col = m.col },
                        }

                        count = count + 1
                        if count >= _max then
                            stop_read = true
                            if sys_obj then sys_obj.kill() end
                            break
                        end
                    end
                end
            end)

            local ok, err = pcall(function()
                sys_obj = spawn(
                    { cmd, unpack(args) },
                    {
                        cwd    = target_cwd,
                        stdout = function(data)
                            if stop_read then return end
                            buffered_feed(data)
                        end,
                        stderr = function(data) on_error(data) end,
                    },
                    function()
                        if my_id == _run_id then
                            _state = { is_replace = is_replace, matches = matches }
                        end
                        callback(items)
                    end
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
        end,
        on_confirm      = function(data)
            if _state.is_replace then
                apply_replacements(_state.matches)
            elseif data and data.filepath and data.lnum then
                uitool.smart_open_file(data.filepath, data.lnum, (data.col or 1) - 1)
            end
        end,
    }
end

return M
