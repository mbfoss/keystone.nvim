# unsaved

Diff every modified buffer against its saved state on disk.

## Configuration

```lua
require("keystone").setup({ unsaved = true })
```

## Commands

| Command | What it does |
| --- | --- |
| `:DiffUnsaved` | Diff unsaved buffers against disk |

The buffer list is presented through `vim.ui.select`, so it uses whichever
implementation you have installed — keystone's [select](select.md) module or
anything else.

---

[← All modules](../README.md#modules)
