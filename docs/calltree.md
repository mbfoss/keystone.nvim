# calltree

A side window showing the LSP call hierarchy of the symbol under the cursor:
who calls it (*incoming*, the default) or what it calls (*outgoing*). Each level
is fetched only when you expand it, so a wide hierarchy costs nothing until you
look at it. A function that reaches itself is marked `↺` and left as a leaf, so
recursion cannot expand forever.

## Configuration

```lua
require("keystone").setup({
  calltree = {
    width_ratio      = 0.25,       -- fraction of the editor width
    position         = "left",     -- side the window opens on ("left"|"right")
    direction        = "incoming", -- which way to walk ("incoming"|"outgoing")
    show_detail      = true,       -- show the server-provided detail text
    auto_expand_root = true,       -- expand the root as soon as it resolves
  },
})
```

## Commands

Open it with `:CallTree` on the symbol you care about. Running it again re-roots
the tree on whatever the cursor is on now, so you can walk the code and keep the
window pointed at where you are — use `toggle` when you actually want it gone.

| Argument | What it does |
| --- | --- |
| *(none)* / `open` | Build the tree for the symbol under the cursor |
| `incoming` / `outgoing` | Same, forcing a direction |
| `swap` | Flip direction, keeping the current root |
| `refresh` | Re-fetch everything from the current root |
| `toggle` | Open, or close if already showing |
| `close` | Close the window |

## Keys

Inside the window, `g?` lists the keys. The essentials:

| Key | What it does |
| --- | --- |
| `<CR>` | Expand or collapse |
| `o` / `O` | Jump to the symbol (`O` also moves focus there) |
| `c` | Jump to the call site |
| `s` | Swap direction |
| `r` | Re-root on the symbol under the cursor |
| `<BS>` | Go back |

---

[← All modules](../README.md#modules)
