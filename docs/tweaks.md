# tweaks

Seven editor behaviours, each behind its own flag. Four are on by default and
three are off, as shown below.

![The yank flash, writing into a directory that does not exist yet, and q closing a help buffer](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/tweaks.gif)

## Configuration

```lua
require("keystone").setup({
  tweaks = {
    highlight_on_yank    = true,  -- briefly highlight yanked text
    restore_cursor       = true,  -- jump to last cursor position when reopening a file
    auto_create_dir      = true,  -- create missing parent directories on save
    auto_reload          = true,  -- reload files changed outside Neovim
    quick_close          = false, -- close help/qf/man/... buffers with q
    disable_auto_comment = false, -- stop auto-continuing comment leaders
    trim_whitespace      = false, -- strip trailing whitespace on save
  },
})
```

---

[← All modules](../README.md#modules)
