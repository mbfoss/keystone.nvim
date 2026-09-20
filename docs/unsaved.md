# unsaved

Diff every modified buffer against its saved state on disk.

<!-- panvimdoc-ignore-start -->

![Diffing an edited buffer against what is still on disk](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/unsaved.gif)

<!-- panvimdoc-ignore-end -->

## Configuration <!-- tag: configuration -->

```lua
require("keystone").setup({ unsaved = true })
```

## Commands <!-- tag: commands -->

| Command | What it does |
| --- | --- |
| `:DiffUnsaved` | Diff unsaved buffers against disk |

<!-- panvimdoc-ignore-start -->

The buffer list goes through `vim.ui.select`. With keystone's
[select](select.md) module enabled, the preview beside the list shows each
buffer's unsaved contents; other implementations may not show a preview.

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
The buffer list goes through `vim.ui.select`. With keystone's |keystone-select|
module enabled, the preview beside the list shows each buffer's unsaved
contents; other implementations may not show a preview.
-->

<!-- panvimdoc-ignore-start -->

---

[← All modules](../README.md#modules)

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
All modules: |keystone-modules|
-->
