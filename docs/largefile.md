# largefile

Opens very large files instantly. Instead of tearing down Treesitter/LSP/
ftplugins after a big file loads, it detects the file during filetype detection
and gives it a sentinel filetype so none of that machinery ever attaches.

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
