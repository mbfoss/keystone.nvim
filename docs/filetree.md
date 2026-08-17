# filetree

A file explorer in a side window.

![Opening the side window and walking into a nested directory](https://github.com/mbfoss/keystone.nvim/releases/download/assets/filetree.gif)

## Configuration

```lua
require("keystone").setup({
  filetree = {
    width_ratio = 0.2,             -- fraction of the editor width
    follow_current_buffer = false, -- reveal the current file as you switch buffers
  },
})
```

Or standalone:

```lua
require("keystone.filetree").setup({ width_ratio = 0.2 })
```

## Commands

| Command | What it does |
| --- | --- |
| `:FileTree` | Toggle the side window |
| `:FileTree open` | Open it |
| `:FileTree close` | Close it |
| `:FileTree toggle` | Same as no argument |

---

[← All modules](../README.md#modules)
