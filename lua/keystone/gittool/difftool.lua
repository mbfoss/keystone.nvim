local M       = {}

local git     = require("keystone.gittool.git")

--- The directory-diff feature behind `:GitTool diff [...]`. It bridges git to
--- Neovim's built-in difftool (`runtime/pack/dist/opt/nvim.difftool`), which
--- only diffs two paths *on disk* and knows nothing about git. We materialise
--- git's two sides of the comparison into a pair of temp directories holding
--- only the changed files, then hand those to `difftool.open`. The built-in
--- derives the A/D/M status from file presence, builds the quickfix index, and
--- drives the side-by-side native diff, so this module stays small: it owns
--- only the git queries and the temp-directory lifecycle; the built-in owns
--- the whole UI.
---
--- Each side is a `GitTool.Side`: a git revision, the index, or the live
--- working tree. Following git-diff semantics:
---   diff                  index    -> working tree   (unstaged changes)
---   diff <rev>            <rev>    -> working tree
---   diff <ref1> <ref2>    <ref1>   -> <ref2>
---   diff --staged         HEAD     -> index
---   diff --staged <rev>   <rev>    -> index
---
--- A working-tree side is materialised as a symlink to the real file, so
--- editing that pane and `:w`-ing writes straight through, matching
--- `git difftool -d`. Revision and index sides are read-only blob copies.

--- The active session's temp directory, kept so a subsequent invocation (or
--- Neovim exit) can delete it. Only one session exists at a time, matching the
--- built-in difftool, whose quickfix list is global.
---@type string?
local _session_dir = nil

--- One side of a comparison. Exactly one field is set.
---@class GitTool.Side
---@field rev      string?  a git revision; content via `git show <rev>:<rel>`
---@field index    boolean? the index (staged); content via `git show :<rel>`
---@field worktree boolean? the live working-tree file (symlinked on its side)

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[keystone] " .. msg, level or vim.log.levels.INFO)
end

--- Resolve parsed CLI options into the left/right sides of the comparison,
--- mirroring git-diff semantics (see the module header).
---@param staged boolean
---@param revs   string[]
---@return GitTool.Side? left
---@return GitTool.Side? right
---@return string?       err  set (with left/right nil) when the args are invalid
local function _resolve_sides(staged, revs)
    if #revs > 2 then
        return nil, nil, "GitTool diff takes at most two revisions"
    end
    if staged then
        if #revs >= 2 then
            return nil, nil, "GitTool diff --staged takes at most one revision"
        end
        return { rev = revs[1] or "HEAD" }, { index = true }
    end
    if #revs >= 2 then
        return { rev = revs[1] }, { rev = revs[2] }
    elseif #revs == 1 then
        return { rev = revs[1] }, { worktree = true }
    end
    -- No revisions: working tree vs the index, matching a bare `git diff`.
    return { index = true }, { worktree = true }
end

--- Human-readable description of the comparison, for the "no changes" message.
---@param staged boolean
---@param revs   string[]
---@return string
local function _describe(staged, revs)
    if staged then
        return "staged changes against " .. (revs[1] or "HEAD")
    elseif #revs >= 2 then
        return "changes between " .. revs[1] .. " and " .. revs[2]
    elseif #revs == 1 then
        return "changes against " .. revs[1]
    end
    return "unstaged changes"
end

--- The set of paths (relative to the repo root) that differ between `left` and
--- `right`. Untracked files are included only when the working tree is the
--- right side (git's own `--name-only` never lists them). Deduped, sorted.
--- The testable seam (no UI, no temp dirs).
---@param root  string repo root
---@param left  GitTool.Side
---@param right GitTool.Side
---@return string[] rels
function M.changed_paths_between(root, left, right)
    local args, include_untracked
    if right.worktree then
        -- Working tree vs a revision (`diff <rev>`) or vs the index (bare `diff`).
        args = { "diff", "--name-only" }
        if left.rev then args[#args + 1] = left.rev end
        include_untracked = true
    elseif right.index then
        args, include_untracked = { "diff", "--name-only", "--cached", left.rev }, false
    else
        args, include_untracked = { "diff", "--name-only", left.rev, right.rev }, false
    end

    local seen = {}
    local rels = {}
    local function add(rel)
        if rel ~= "" and not seen[rel] then
            seen[rel]       = true
            rels[#rels + 1] = rel
        end
    end

    for _, rel in ipairs(git.lines((git.run(root, args)))) do
        add(rel)
    end
    if include_untracked then
        for _, rel in ipairs(git.lines((git.run(root, { "ls-files", "--others", "--exclude-standard" })))) do
            add(rel)
        end
    end

    table.sort(rels)
    return rels
end

--- Back-compat shorthand for "working tree vs `rev`".
---@param root string repo root
---@param rev  string
---@return string[] rels
function M.changed_paths(root, rev)
    return M.changed_paths_between(root, { rev = rev }, { worktree = true })
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

--- Materialise one changed path's content for `side` into `dir`. An absent
--- slot (file not present on this side) is left empty, so the built-in derives
--- `A`/`D` from the missing file.
---@param root string repo root
---@param side GitTool.Side
---@param dir  string this side's session dir
---@param rel  string path relative to root
local function _materialise_side(root, side, dir, rel)
    -- Working-tree side: a symlink to the live file, so edits + `:w` write
    -- through. Absent on disk (deleted) -> leave empty.
    if side.worktree then
        local src = root .. "/" .. rel
        if vim.fn.filereadable(src) == 1 then
            local link = dir .. "/" .. rel
            vim.fn.mkdir(vim.fs.dirname(link), "p")
            vim.uv.fs_symlink(src, link)
        end
        return
    end

    -- Git side: the blob from a revision (`<rev>:<rel>`) or the index
    -- (`:<rel>`). Absent there (added/deleted) -> leave empty.
    local spec = side.rev and (side.rev .. ":" .. rel) or (":" .. rel)
    local blob = git.run_raw(root, { "show", spec })
    if blob ~= nil then
        _write_file(dir .. "/" .. rel, blob)
    end
end

--- Delete the previous session's temp directory, if any. Also the
--- `VimLeavePre` cleanup hook.
function M.clear_session()
    if _session_dir then
        vim.fn.delete(_session_dir, "rf")
        _session_dir = nil
    end
end

---@class GitTool.DiffOpts
---@field staged boolean?  compare the index instead of the working tree
---@field revs   string[]? zero, one, or two revisions (see git-diff semantics)

--- Diff using the built-in difftool. See the module header for the full
--- revision/`--staged` semantics; with no options it compares the working tree
--- against the index (a bare `git diff` -- the unstaged changes).
---@param opts GitTool.DiffOpts?
function M.diff(opts)
    opts = opts or {}
    local staged = opts.staged or false
    local revs = opts.revs or {}

    local left, right, err = _resolve_sides(staged, revs)
    if err then
        _notify(err, vim.log.levels.ERROR)
        return
    end
    ---@cast left GitTool.Side
    ---@cast right GitTool.Side

    -- The built-in difftool is an optional core plugin; make sure it is loaded.
    pcall(vim.cmd, "packadd nvim.difftool")
    local ok, difftool = pcall(require, "difftool")
    if not ok or type(difftool.open) ~= "function" then
        _notify("GitTool requires Neovim's built-in nvim.difftool (Neovim >= 0.12)",
            vim.log.levels.ERROR)
        return
    end

    local root = git.root()
    if not root then
        _notify("Not inside a git repository", vim.log.levels.WARN)
        return
    end

    for _, side in ipairs({ left, right }) do
        if side.rev and not git.verify_rev(root, side.rev) then
            _notify("Unknown revision: " .. side.rev, vim.log.levels.ERROR)
            return
        end
    end

    local rels = M.changed_paths_between(root, left, right)
    if #rels == 0 then
        _notify("No " .. _describe(staged, revs))
        return
    end

    -- Fresh session: drop the previous temp dir, build new left/right dirs.
    M.clear_session()
    local base      = vim.fn.tempname()
    local left_dir  = base .. "/left"
    local right_dir = base .. "/right"
    vim.fn.mkdir(left_dir, "p")
    vim.fn.mkdir(right_dir, "p")
    _session_dir = base

    for _, rel in ipairs(rels) do
        _materialise_side(root, left, left_dir, rel)
        _materialise_side(root, right, right_dir, rel)
    end

    -- The built-in takes over from here: directory diff -> quickfix + layout.
    difftool.open(left_dir, right_dir)
end

return M
