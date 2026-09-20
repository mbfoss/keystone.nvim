# calltree

A side window showing the LSP call hierarchy of the symbol under the cursor: who
calls it (*incoming*, the default) or what it calls (*outgoing*). Levels are
fetched on expand. A function that reaches itself is marked `↺` and left as a
leaf.

<!-- panvimdoc-ignore-start -->

![Incoming calls to a function, expanded a level at a time, then flipped to outgoing](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/calltree.gif)

<!-- panvimdoc-ignore-end -->

## Configuration <!-- tag: configuration -->

```lua
require("keystone").setup({
  calltree = {
    width_ratio      = 0.2,        -- fraction of the editor width (left/right)
    height_ratio     = 0.3,        -- fraction of the editor height (top/bottom)
    position         = "bottom",   -- side the window opens on
                                   -- ("top"|"bottom"|"left"|"right")
    direction        = "incoming", -- which way to walk ("incoming"|"outgoing")
    show_detail      = true,       -- show the server-provided detail text
    auto_expand_root = true,       -- expand the root as soon as it resolves
  },
})
```

## Commands <!-- tag: commands -->

Open it with `:CallTree` on the symbol to inspect. Running it again re-roots the
tree on the cursor's current position; use `toggle` to close it.

| Argument | What it does |
| --- | --- |
| *(none)* / `open` | Build the tree for the symbol under the cursor |
| `incoming` / `outgoing` | Same, forcing a direction |
| `swap` | Flip direction, keeping the current root |
| `refresh` | Re-fetch everything from the current root |
| `toggle` | Open, or close if already showing |
| `close` | Close the window |

## Keys <!-- tag: keys -->

Inside the window, `g?` lists the keys. The main ones:

| Key | What it does |
| --- | --- |
| `<CR>` / `za` | Expand or collapse |
| `o` / `O` | Jump to the call site (`O` also moves focus there) |
| `K` | Hover info (kind, location, call sites) |
| `<Tab>` | Swap direction |
| `r` | Re-root on the symbol under the cursor |
| `<BS>` | Back to the previous root |
| `R` | Refresh |

The root line is tagged with what the rows beneath it are: `CALLERS` for
incoming, `CALLS` for outgoing.

<!-- panvimdoc-ignore-start -->

---

[← All modules](../README.md#modules)

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
All modules: |keystone-modules|
-->
