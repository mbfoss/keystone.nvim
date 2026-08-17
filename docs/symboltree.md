# symboltree

A side window showing the LSP document symbols of the current buffer, refreshed
as you edit and able to follow the cursor.

![The document outline: expanding a symbol, jumping the source pane, hover info](https://raw.githubusercontent.com/mbfoss/keystone.nvim/assets/symboltree.gif)

## Configuration

```lua
require("keystone").setup({
  symboltree = {
    width_ratio    = 0.2,   -- fraction of the editor width
    track_cursor   = true,  -- highlight/follow the symbol under the cursor
    auto_expand    = true,  -- expand every symbol on load
    show_detail    = true,  -- show the server-provided detail text
    exclude_kinds  = nil,   -- LSP symbol kind names to hide, e.g. { "Variable" }
    collapse_kinds = { "Function", "Method", "Object" },
                            -- kinds left collapsed on load even when auto_expand is set
    debounce_ms    = 500,   -- edit-to-refresh delay
  },
})
```

`exclude_kinds` and `collapse_kinds` are replaced outright when you set them —
they are not merged with the defaults.

## Commands

| Command | What it does |
| --- | --- |
| `:SymbolTree` | Toggle the side window |
| `:SymbolTree open` | Open it |
| `:SymbolTree close` | Close it |
| `:SymbolTree toggle` | Same as no argument |

## Keys

`g?` inside the window lists them all. Folding uses the usual `za`/`zc`/`zo`
(and `zC`/`zO` to recurse); `K` shows hover info for the symbol under the cursor
and `R` refreshes.

---

[← All modules](../README.md#modules)
