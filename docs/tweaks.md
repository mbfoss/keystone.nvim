# tweaks

A collection of quality-of-life editor behaviours. Each is an independent flag,
so you can enable exactly the ones you want.

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
