local M   = {}

local git = require("keystone.gittool.git")

--- The single-file feature behind `:GitTool diffthis [<rev>]`. It diffs the
--- *current buffer* -- including unsaved edits -- against its git version using
--- Neovim's native diff mode in a side split. No temp files and no quickfix:
--- for one file the built-in `:diffthis` is enough. The git side (default: the
--- index, i.e. a bare `git diff <file>`) is materialised in a read-only scratch
--- buffer on the left; the live buffer stays on the right, so the diff tracks
--- edits as you type.

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[keystone] " .. msg, level or vim.log.levels.INFO)
end

--- Split a git blob into buffer lines, dropping the single trailing newline a
--- well-formed text file ends with (otherwise `split` yields a phantom blank
--- last line).
---@param blob string
---@return string[]
local function _blob_lines(blob)
    if blob:sub(-1) == "\n" then
        blob = blob:sub(1, -2)
    end
    return vim.split(blob, "\n", { plain = true })
end

--- Tear down a diffthis session once the diff ends, however it ends. The
--- `gittool://` side is a throwaway scratch buffer, so drop it rather than
--- leave it lingering in the buffer list. If a window still shows it -- the
--- user closed the *live* side first -- send that window back to the live file
--- (a window must always hold some buffer; fall back to a fresh one if the live
--- buffer is gone too) before wiping. Either way, clear diff mode off the
--- surviving live window so it is not left with the diff's fold column.
---@param buf   integer  the live file buffer
---@param base  integer  the gittool:// scratch buffer
---@param group integer  the session's autocmd group
local function _end_diff(buf, base, group)
    -- Fire once: dropping the group also unhooks the BufWipeout below, so the
    -- buffer wipe we trigger here cannot re-enter.
    vim.api.nvim_del_augroup_by_id(group)

    -- Defer the actual teardown: editing windows/buffers straight from a
    -- WinClosed or BufWipeout callback runs into textlock.
    vim.schedule(function()
        -- A window still on the scratch buffer means the live side closed
        -- first; send it back to the live file (its bufhidden=wipe then wipes
        -- the scratch buffer out from under it), or to a fresh buffer if the
        -- live file is gone too.
        for _, win in ipairs(vim.fn.win_findbuf(base)) do
            if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_win_set_buf(win, buf)
            else
                vim.api.nvim_win_call(win, function() vim.cmd("enew") end)
            end
        end
        if vim.api.nvim_buf_is_valid(base) then
            vim.api.nvim_buf_delete(base, { force = true })
        end

        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
            vim.api.nvim_win_call(win, function() vim.cmd("diffoff") end)
        end
    end)
end

---@class GitTool.DiffThisOpts
---@field rev string?  revision to compare against; nil = the index

--- Diff the current buffer against `opts.rev` (default: the index).
---@param opts GitTool.DiffThisOpts?
function M.diffthis(opts)
    opts = opts or {}
    local rev = opts.rev -- nil => the index

    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype ~= "" then
        _notify("GitTool diffthis needs a normal file buffer", vim.log.levels.WARN)
        return
    end

    local abs = vim.api.nvim_buf_get_name(buf)
    if abs == "" then
        _notify("Current buffer has no file name", vim.log.levels.WARN)
        return
    end
    abs = vim.fn.fnamemodify(abs, ":p")

    local root = git.root(vim.fs.dirname(abs))
    if not root then
        _notify("Not inside a git repository", vim.log.levels.WARN)
        return
    end

    local rel = git.relpath(root, abs)
    if not rel then
        _notify("File is outside the repository: " .. abs, vim.log.levels.WARN)
        return
    end

    if rev and not git.verify_rev(root, rev) then
        _notify("Unknown revision: " .. rev, vim.log.levels.ERROR)
        return
    end

    -- The git side: blob at `<rev>:<rel>` (or the index, `:<rel>`). Absent
    -- there (a newly added file) -> an empty base, so it all shows as added.
    local spec = rev and (rev .. ":" .. rel) or (":" .. rel)
    local blob = git.run_raw(root, { "show", spec })
    local base_lines = blob and _blob_lines(blob) or {}

    -- Read-only scratch buffer for the git side, mirroring the live buffer's
    -- filetype so syntax highlighting matches.
    local base = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(base, 0, -1, false, base_lines)
    vim.bo[base].buftype = "nofile"
    vim.bo[base].bufhidden = "wipe"
    vim.bo[base].swapfile = false
    vim.bo[base].filetype = vim.bo[buf].filetype
    vim.bo[base].modifiable = false
    pcall(vim.api.nvim_buf_set_name, base,
        ("gittool://%s/%s"):format(rev or "index", rel))

    -- Lay it out: git side in a split to the left, live buffer on the right;
    -- turn on diff mode in both windows.
    local cur_win = vim.api.nvim_get_current_win()
    vim.cmd("leftabove vsplit")
    vim.api.nvim_win_set_buf(0, base)
    vim.cmd("diffthis")
    vim.api.nvim_set_current_win(cur_win)
    vim.cmd("diffthis")

    -- Tear the scratch buffer down when the diff ends. Closing its own window
    -- wipes it (bufhidden=wipe) and fires BufWipeout; closing the live window
    -- instead strands it on screen, which the WinClosed hook catches. One
    -- group per session, keyed by the scratch buffer's id.
    local group = vim.api.nvim_create_augroup(
        ("keystone.gittool.diffthis.%d"):format(base), { clear = true })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group    = group,
        buffer   = base,
        callback = function() _end_diff(buf, base, group) end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        group    = group,
        pattern  = tostring(cur_win),
        callback = function() _end_diff(buf, base, group) end,
    })
end

return M
