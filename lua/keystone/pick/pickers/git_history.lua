---@meta

---@class GitCommitEntry
---@field hash    string  -- full commit hash
---@field short   string  -- abbreviated hash
---@field author  string
---@field date    string  -- relative date
---@field subject string

local M = {}

local spawn = require("keystone.util.spawn")

-- Field separator (unit separator) inside a single commit record; records
-- themselves are NUL-separated by `git log -z`.
local _FS = "\31"

-- The well-known empty tree object, used as the "parent" of a root commit.
local _EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

---@type keystone.queryflags.FlagDef[]
local FLAGS = {
    { name = "content", type = "boolean",                desc = "search commit diffs (pickaxe) instead of messages" },
    { name = "regex",   type = "boolean",                desc = "treat query as a regex"                            },
    { name = "case",    type = "boolean",                desc = "case-sensitive"                                    },
    { name = "author",  type = "value",                  desc = "filter by author"                                  },
    { name = "all",     type = "boolean",                desc = "search all refs/branches"                          },
    { name = "in",      type = "value",  multi = true,   desc = "limit to path(s)"                                  },
}

---@param query string
---@param flags table
---@return string[] args
local function build_log_args(query, flags)
    local args = {
        "log",
        "--no-color",
        "-z",
        "-n", "2000",
        "--format=%H" .. _FS .. "%h" .. _FS .. "%an" .. _FS .. "%ar" .. _FS .. "%s",
    }

    if flags.all then
        table.insert(args, "--all")
    end

    if not flags.case then
        table.insert(args, "-i")
    end

    if flags.author then
        table.insert(args, "--author=" .. flags.author)
    end

    if query ~= "" then
        if flags.content then
            -- Pickaxe: -G is a regex over the diff, -S matches occurrence count
            -- changes of a literal/regex string.
            table.insert(args, flags.regex and ("-G" .. query) or ("-S" .. query))
        else
            table.insert(args, "--grep=" .. query)
            if not flags.regex then
                table.insert(args, "--fixed-strings")
            end
        end
    end

    table.insert(args, "--")
    for _, p in ipairs(flags["in"] or {}) do
        table.insert(args, p)
    end

    return args
end

---@param raw string
---@return GitCommitEntry[]
local function parse_commits(raw)
    local commits = {}
    local start   = 1

    while true do
        local nxt    = raw:find("\0", start, true)
        local record = nxt and raw:sub(start, nxt - 1) or raw:sub(start)
        record       = record:gsub("^\n", "")

        if record ~= "" then
            local fields = vim.split(record, _FS, { plain = true })
            if fields[1] and fields[1] ~= "" then
                table.insert(commits, {
                    hash    = fields[1],
                    short   = fields[2] or "",
                    author  = fields[3] or "",
                    date    = fields[4] or "",
                    subject = fields[5] or "",
                })
            end
        end

        if not nxt then break end
        start = nxt + 1
    end

    return commits
end

---@param query      string
---@param flags      table
---@param cwd        string
---@param callback   fun(items:table[]?)
---@return fun()? cancel
local function async_log(query, flags, cwd, callback)
    local args   = build_log_args(query, flags)
    local chunks = {}
    local errbuf = {}
    local sys_obj

    local ok, err = pcall(function()
        sys_obj = spawn(
            { "git", unpack(args) },
            {
                cwd    = cwd,
                stdout = function(data) table.insert(chunks, data) end,
                stderr = function(data) table.insert(errbuf, data) end,
            },
            function(code)
                if code ~= 0 then
                    local msg = vim.trim(table.concat(errbuf)):gsub("\n", " ")
                    callback({ {
                        label_chunks = { { "ERROR: ", "Error" }, { msg ~= "" and msg or "git log failed" } },
                        data         = {},
                    } })
                    return
                end

                local commits = parse_commits(table.concat(chunks))
                local items   = {}
                for _, c in ipairs(commits) do
                    table.insert(items, {
                        label_chunks = {
                            { c.short, "Identifier" },
                            { " " },
                            { c.subject },
                        },
                        virt_lines   = { { { c.author .. " · " .. c.date, "Comment" } } },
                        data         = c,
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

    return function() if sys_obj then sys_obj.kill() end end
end

---Write the content of `<rev>:<path>` to `dest`, creating parent dirs.
---@param cwd  string
---@param rev  string
---@param path string
---@param dest string
---@return boolean ok
local function git_show_to_file(cwd, rev, path, dest)
    local out = vim.system(
        { "git", "--no-pager", "show", rev .. ":" .. path },
        { cwd = cwd, text = false }
    ):wait()
    if out.code ~= 0 then return false end

    vim.fn.mkdir(vim.fn.fnamemodify(dest, ":h"), "p")
    local f = io.open(dest, "wb")
    if not f then return false end
    f:write(out.stdout or "")
    f:close()
    return true
end

---Materialize the files a commit touched (old + new versions) into two temp
---directories suitable for `DiffTool`.
---@param cwd    string
---@param parent string  -- parent rev (or empty-tree sha for a root commit)
---@param hash   string
---@return string? left_dir, string? right_dir
local function materialize_commit(cwd, parent, hash)
    local ns = vim.system(
        { "git", "diff", "--name-status", "-z", parent, hash },
        { cwd = cwd }
    ):wait()
    if ns.code ~= 0 then
        vim.notify("git diff failed: " .. vim.trim(ns.stderr or ""), vim.log.levels.ERROR)
        return nil
    end

    local base      = vim.fn.tempname()
    local left_dir  = base .. "/a"
    local right_dir = base .. "/b"
    vim.fn.mkdir(left_dir, "p")
    vim.fn.mkdir(right_dir, "p")

    local toks = vim.split(ns.stdout or "", "\0", { plain = true })
    local i    = 1
    local any  = false

    while i <= #toks do
        local status = toks[i]
        if not status or status == "" then break end
        local code = status:sub(1, 1)

        if code == "R" or code == "C" then
            local oldp, newp = toks[i + 1], toks[i + 2]
            i = i + 3
            if oldp and oldp ~= "" then
                any = git_show_to_file(cwd, parent, oldp, left_dir .. "/" .. oldp) or any
            end
            if newp and newp ~= "" then
                any = git_show_to_file(cwd, hash, newp, right_dir .. "/" .. newp) or any
            end
        else
            local path = toks[i + 1]
            i = i + 2
            if path and path ~= "" then
                if code == "A" then
                    any = git_show_to_file(cwd, hash, path, right_dir .. "/" .. path) or any
                elseif code == "D" then
                    any = git_show_to_file(cwd, parent, path, left_dir .. "/" .. path) or any
                else -- M, T, ...
                    local l = git_show_to_file(cwd, parent, path, left_dir .. "/" .. path)
                    local r = git_show_to_file(cwd, hash, path, right_dir .. "/" .. path)
                    any = l or r or any
                end
            end
        end
    end

    if not any then return nil end
    return left_dir, right_dir
end

---@class keystone.githistory.opts
---@field cwd string?

---@param opts keystone.githistory.opts?
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
        prompt          = "Git History",
        flags           = FLAGS,
        enable_preview  = true,
        enable_list_sep = true,
        finder          = function(query, flags, _, callback, _)
            return async_log(query, flags, cwd, callback)
        end,
        previewer       = function(data, _, callback)
            if not data or not data.hash then
                vim.schedule(function() callback({ content = "" }) end)
                return function() end
            end

            local sys_obj = vim.system(
                { "git", "show", "--no-color", "--stat", "-p", data.hash },
                { cwd = cwd },
                function(out)
                    local content = out.stdout or ""
                    if content == "" then content = "No diff available" end
                    vim.schedule(function()
                        callback({ content = content, filetype = "git" })
                    end)
                end
            )
            return function() sys_obj:kill("sigterm") end
        end,
        on_confirm      = function(data)
            if not data or not data.hash then return end

            local ok = pcall(vim.cmd.packadd, "nvim.difftool")
            if not ok then
                vim.notify("nvim.difftool is not available (requires Neovim 0.12+)", vim.log.levels.ERROR)
                return
            end

            -- Resolve the parent; fall back to the empty tree for a root commit.
            local parent = _EMPTY_TREE
            local p = vim.system(
                { "git", "rev-parse", "--verify", "--quiet", data.hash .. "^" },
                { cwd = cwd }
            ):wait()
            if p.code == 0 and vim.trim(p.stdout or "") ~= "" then
                parent = vim.trim(p.stdout)
            end

            local left_dir, right_dir = materialize_commit(cwd, parent, data.hash)
            if not left_dir or not right_dir then
                vim.notify("No file changes in commit " .. data.short, vim.log.levels.INFO)
                return
            end

            require("difftool").open(left_dir, right_dir, { rename = { detect = true } })
        end,
    }
end

return M
