-- Individual quality-of-life behaviours, each self-contained in its own
-- augroup so the parent module can enable/disable them independently. Every
-- feature exposes `augroup` (the name used for teardown) and `setup(config)`
-- (installs its autocmds / options).

local M = {}

---@class keystone.tweaks.Feature
---@field augroup string augroup name, also used to tear the feature down
---@field setup fun(config: keystone.tweaks.Config) install autocmds/options

-- The yank/highlight API moved from `vim.highlight` to `vim.hl` in 0.11;
-- prefer the new home and fall back so we work on 0.10 too.
local function _hl()
  return vim.hl or vim.highlight
end

-- Briefly flash the just-yanked region. Purely visual feedback; nothing here
-- changes buffer contents.
---@type keystone.tweaks.Feature
M.highlight_on_yank = {
  augroup = "keystone_tweaks_yank",
  setup = function(config)
    local group = vim.api.nvim_create_augroup("keystone_tweaks_yank", { clear = true })
    vim.api.nvim_create_autocmd("TextYankPost", {
      group = group,
      desc = "Highlight yanked text",
      callback = function()
        _hl().on_yank({ higroup = config.yank_hlgroup, timeout = config.yank_timeout })
      end,
    })
  end,
}

-- Restore the cursor to its last position when reopening a file. Skips special
-- buffers and commit/rebase buffers, where jumping to the previous line is
-- almost never what you want.
---@type keystone.tweaks.Feature
M.restore_cursor = {
  augroup = "keystone_tweaks_restore_cursor",
  setup = function()
    local group = vim.api.nvim_create_augroup("keystone_tweaks_restore_cursor", { clear = true })
    vim.api.nvim_create_autocmd("BufReadPost", {
      group = group,
      desc = "Restore last cursor position",
      callback = function(args)
        local buf = args.buf
        if vim.bo[buf].buftype ~= "" then return end
        local ft = vim.bo[buf].filetype
        if ft ~= "" then return end
        local mark = vim.api.nvim_buf_get_mark(buf, '"')
        local line = mark[1]
        if line > 0 and line <= vim.api.nvim_buf_line_count(buf) then
          pcall(vim.api.nvim_win_set_cursor, 0, mark)
        end
      end,
    })
  end,
}

-- Create missing parent directories when writing a new file, so `:e
-- a/b/c.lua` followed by `:w` just works.
---@type keystone.tweaks.Feature
M.auto_create_dir = {
  augroup = "keystone_tweaks_auto_create_dir",
  setup = function()
    local group = vim.api.nvim_create_augroup("keystone_tweaks_auto_create_dir", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = group,
      desc = "Create missing parent directories on save",
      callback = function(args)
        -- Leave non-file targets (scp://, oil://, ...) to their handlers.
        if args.match:match("^%w+://") then return end
        local dir = vim.fn.fnamemodify(args.match, ":p:h")
        if vim.fn.isdirectory(dir) == 0 then
          vim.fn.mkdir(dir, "p")
        end
      end,
    })
  end,
}

-- Pick up edits made to a file outside Neovim. `autoread` reloads unchanged
-- buffers; the `checktime` triggers make that happen the moment you refocus or
-- switch back to the buffer rather than only on the next command.
---@type keystone.tweaks.Feature
M.auto_reload = {
  augroup = "keystone_tweaks_auto_reload",
  setup = function()
    vim.o.autoread = true
    local group = vim.api.nvim_create_augroup("keystone_tweaks_auto_reload", { clear = true })
    vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "TermClose", "TermLeave" }, {
      group = group,
      desc = "Check for external file changes",
      callback = function()
        -- `checktime` is illegal from the command-line window / command mode.
        if vim.o.buftype ~= "" then return end
        if vim.fn.mode() == "c" or vim.fn.getcmdwintype() ~= "" then return end
        pcall(vim.cmd.checktime)
      end,
    })
    vim.api.nvim_create_autocmd("FileChangedShellPost", {
      group = group,
      desc = "Notify when a buffer is reloaded from disk",
      callback = function()
        vim.notify("File changed on disk — buffer reloaded", vim.log.levels.WARN)
      end,
    })
  end,
}

-- Re-balance split sizes when the terminal/Neovim window is resized, so panes
-- don't end up lopsided after a font change or terminal resize.
---@type keystone.tweaks.Feature
M.equalize_splits = {
  augroup = "keystone_tweaks_equalize_splits",
  setup = function()
    local group = vim.api.nvim_create_augroup("keystone_tweaks_equalize_splits", { clear = true })
    vim.api.nvim_create_autocmd("VimResized", {
      group = group,
      desc = "Equalize splits on resize",
      callback = function()
        local tab = vim.api.nvim_get_current_tabpage()
        vim.cmd("tabdo wincmd =")
        pcall(vim.api.nvim_set_current_tabpage, tab)
      end,
    })
  end,
}

-- Let `q` close throwaway/utility buffers (help, quickfix, man, ...) the way
-- you'd expect, instead of having to `:q`.
---@type keystone.tweaks.Feature
M.quick_close = {
  augroup = "keystone_tweaks_quick_close",
  setup = function(config)
    local group = vim.api.nvim_create_augroup("keystone_tweaks_quick_close", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = config.quick_close_filetypes,
      desc = "Close utility buffers with q",
      callback = function(args)
        vim.keymap.set("n", "q", "<cmd>close<cr>", {
          buffer = args.buf,
          silent = true,
          nowait = true,
          desc = "Close window",
        })
      end,
    })
  end,
}

-- Stop Neovim from continuing comment leaders onto the next line (when pressing
-- `o`/`O` or hitting <CR> in insert). Runs on FileType so it wins against the
-- ftplugins that set `formatoptions`.
---@type keystone.tweaks.Feature
M.disable_auto_comment = {
  augroup = "keystone_tweaks_disable_auto_comment",
  setup = function()
    local group = vim.api.nvim_create_augroup("keystone_tweaks_disable_auto_comment", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      desc = "Disable auto comment continuation",
      callback = function()
        vim.opt_local.formatoptions:remove({ "c", "r", "o" })
      end,
    })
  end,
}

-- Strip trailing whitespace on save. Off by default because, unlike the other
-- features, it rewrites buffer contents.
---@type keystone.tweaks.Feature
M.trim_whitespace = {
  augroup = "keystone_tweaks_trim_whitespace",
  setup = function()
    local group = vim.api.nvim_create_augroup("keystone_tweaks_trim_whitespace", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = group,
      desc = "Trim trailing whitespace on save",
      callback = function(args)
        if vim.bo[args.buf].binary then return end
        local view = vim.fn.winsaveview()
        vim.cmd([[silent! keeppatterns %s/\s\+$//e]])
        vim.fn.winrestview(view)
      end,
    })
  end,
}

return M
