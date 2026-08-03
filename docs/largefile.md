# largefile

Opens files above a size threshold without attaching Treesitter, LSP or
ftplugins. Rather than tearing that machinery down after the file has loaded, it
checks the size during filetype detection and assigns a sentinel filetype, so
the `FileType` handlers for the real filetype never fire.

![Opening and moving around a 23 MB, 240k-line log](assets/largefile.gif)

## Configuration

```lua
require("keystone").setup({
  largefile = {
    size_threshold   = 1024 * 1024, -- bytes above which a file is treated as large
    keep_syntax      = true,        -- restore cheap regex syntax for the real filetype
    disable_folding  = true,
    disable_swapfile = true,
    disable_undofile = true,
    notify           = false,       -- announce when a buffer opens in fast mode
  },
})
```

---

[← All modules](../README.md#modules)
