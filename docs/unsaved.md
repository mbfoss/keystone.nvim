# unsaved

Diff every modified buffer against its saved state on disk.

![Diffing an edited buffer against what is still on disk](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/unsaved.gif)

## Configuration

```lua
require("keystone").setup({ unsaved = true })
```

## Commands

| Command | What it does |
| --- | --- |
| `:DiffUnsaved` | Diff unsaved buffers against disk |

The buffer list is presented through `vim.ui.select`, so it uses whichever
implementation you have installed. With keystone's [select](select.md) module
enabled, the preview beside the list shows each buffer's unsaved contents;
other implementations just list the buffers.

---

[← All modules](../README.md#modules)
