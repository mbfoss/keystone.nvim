local M           = {}

local usercmd     = require("keystone.util.usercmd")

--- `:GitTool diff [<rev>]` — a git-backed front end for Neovim's built-in
--- difftool (`runtime/pack/dist/opt/nvim.difftool`). The built-in only diffs
--- two paths *on disk*; it knows nothing about git. We bridge the two by
--- materialising git's two sides of the comparison into a pair of temp
--- directories holding only the changed files -- the `<rev>` version of each
--- file on the left, a symlink to the live working-tree file on the right --
--- then handing those directories to `difftool.open`. The built-in derives the
--- A/D/M status from file presence, builds the quickfix index, and drives the
--- side-by-side native diff, so this module stays small: it owns only the git
--- queries and the temp-directory lifecycle; the built-in owns the whole UI.
---
--- Symlinking the working-tree side (rather than copying) means editing the
--- right pane and `:w`-ing writes straight through to the real file, matching
--- `git difftool -d` semantics.

--- The active session's temp directory, kept so a subsequent invocation (or
--- Neovim exit) can delete it. Only one session exists at a time, matching the
--- built-in difftool, whose quickfix list is global.
---@type string?
local _session_dir = nil

local _AUGROUP     = "keystone.gittool"

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[keystone] " .. msg, level or vim.log.levels.INFO)
end

--- Run `git <args>` in `cwd`. Returns trimmed stdout on success, or nil with
--- the (trimmed) stderr on failure.
---@param cwd  string
---@param args string[]
---@return string? stdout
---@return string? stderr
local function _git(cwd, args)
    local cmd = { "git" }
    vim.list_extend(cmd, args)
    local res = vim.system(cmd, { text = true, cwd = cwd }):wait()
    if res.code ~= 0 then
        return nil, vim.trim(res.stderr or "")
    end
    return vim.trim(res.stdout or ""), nil
end

--- Split git's newline-delimited path output into a list, dropping blanks.
---@param out string?
---@return string[]
local function _lines(out)
    if not out or out == "" then return {} end
    return vim.split(out, "\n", { trimempty = true })
end

--- The set of paths (relative to the repo root) that differ between `rev` and
--- the working tree: tracked changes plus untracked files. Deduped, sorted.
--- Factored out as the testable seam (no UI, no temp dirs).
---@param root string repo root
---@param rev  string
---@return string[] rels
function M._changed_paths(root, rev)
    local seen = {}
    local rels = {}
    local function add(rel)
        if rel ~= "" and not seen[rel] then
            seen[rel]      = true
            rels[#rels + 1] = rel
        end
    end

    for _, rel in ipairs(_lines((_git(root, { "diff", "--name-only", rev })))) do
        add(rel)
    end
    for _, rel in ipairs(_lines((_git(root, { "ls-files", "--others", "--exclude-standard" })))) do
        add(rel)
    end

    table.sort(rels)
    return rels
end

--- Write `data` to `path` byte-for-byte, creating parent directories. Binary
--- safe (unlike `writefile`, which is line-oriented), so blobs round-trip.
---@param path string
---@param data string
local function _write_file(path, data)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local fd = io.open(path, "wb")
    if not fd then return end
    fd:write(data)
    fd:close()
end

--- Materialise one changed path into the left/right session directories.
---@param root  string repo root
---@param rev   string
---@param left  string left (rev) session dir
---@param right string right (working tree) session dir
---@param rel   string path relative to root
local function _materialise(root, rev, left, right, rel)
    -- Left side: the file's content at `rev`. Absent in `rev` (file was added
    -- or is untracked) -> leave the slot empty so the built-in marks it `A`.
    local blob = _git(root, { "show", rev .. ":" .. rel })
    if blob ~= nil then
        _write_file(left .. "/" .. rel, blob)
    end

    -- Right side: a symlink to the live working-tree file, so edits + `:w`
    -- write through. Absent on disk (deleted) -> leave empty so it marks `D`.
    local src = root .. "/" .. rel
    if vim.fn.filereadable(src) == 1 then
        local link = right .. "/" .. rel
        vim.fn.mkdir(vim.fs.dirname(link), "p")
        vim.uv.fs_symlink(src, link)
    end
end

--- Delete the previous session's temp directory, if any.
local function _clear_session()
    if _session_dir then
        vim.fn.delete(_session_dir, "rf")
        _session_dir = nil
    end
end

--- Diff the working tree against `rev` (default `HEAD`) using the built-in
--- difftool.
---@param rev string?
function M.diff(rev)
    rev = (rev and rev ~= "") and rev or "HEAD"

    -- The built-in difftool is an optional core plugin; make sure it is loaded.
    pcall(vim.cmd, "packadd nvim.difftool")
    local ok, difftool = pcall(require, "difftool")
    if not ok or type(difftool.open) ~= "function" then
        _notify("GitTool requires Neovim's built-in nvim.difftool (Neovim >= 0.12)",
            vim.log.levels.ERROR)
        return
    end

    local root = _git(vim.uv.cwd() or ".", { "rev-parse", "--show-toplevel" })
    if not root then
        _notify("Not inside a git repository", vim.log.levels.WARN)
        return
    end

    if not _git(root, { "rev-parse", "--verify", "--quiet", rev .. "^{commit}" }) then
        _notify("Unknown revision: " .. rev, vim.log.levels.ERROR)
        return
    end

    local rels = M._changed_paths(root, rev)
    if #rels == 0 then
        _notify("No changes against " .. rev)
        return
    end

    -- Fresh session: drop the previous temp dir, build new left/right dirs.
    _clear_session()
    local base  = vim.fn.tempname()
    local left  = base .. "/left"
    local right = base .. "/right"
    vim.fn.mkdir(left, "p")
    vim.fn.mkdir(right, "p")
    _session_dir = base

    for _, rel in ipairs(rels) do
        _materialise(root, rev, left, right, rel)
    end

    -- The built-in takes over from here: directory diff -> quickfix + layout.
    difftool.open(left, right)
end

--- Register `:GitTool`. Auto-called by the central module loader.
function M.setup()
    local group = vim.api.nvim_create_augroup(_AUGROUP, { clear = true })
    -- We own only the temp-dir lifecycle; the built-in difftool owns its own
    -- windows/quickfix teardown.
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group    = group,
        callback = _clear_session,
    })

    usercmd.register_user_cmd("GitTool", function(_, args)
        if args[1] == "diff" then
            M.diff(args[2])
        else
            _notify("Usage: GitTool diff [<rev>]", vim.log.levels.WARN)
        end
    end, {
        desc          = "Git diff via Neovim's built-in difftool",
        subcommand_fn = function(_, rest)
            if #rest == 0 then return { "diff" } end
            return {}
        end,
    })
end

return M
