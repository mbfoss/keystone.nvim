# select

Replaces `vim.ui.select` — the prompt Neovim shows whenever something asks you
to choose from a list (LSP code actions, `:DiffUnsaved`, other
plugins) — with a floating one: a prompt line, a fuzzy-filtered list, and a
preview window for callers that offer one.

![A vim.ui.select prompt with fuzzy filtering and a live preview](https://raw.githubusercontent.com/mbfoss/keystone.nvim/assets/select.gif)

## Configuration

```lua
require("keystone").setup({
  select = {
    sort            = false, -- order filtered items by fuzzy score, not the caller's order
    with_preview    = {      -- sizing when the caller offers a preview
      width_ratio  = 0.8,     -- fraction of the editor width the picker occupies
      height_ratio = 0.7,     -- fraction of the editor height the picker occupies
    },
    without_preview = {      -- sizing when it does not; the items decide, within these
      min_width_ratio  = 0.4, -- width the list keeps however narrow its labels
      max_width_ratio  = 0.8, -- width the widest label may grow the list to
      min_height_ratio = 0.2, -- height the list keeps however few the items
      max_height_ratio = 0.7, -- height the picker may grow to
    },
  },
})
```

Filtering keeps the caller's order by default, so items stay where you last saw
them as you type; set `sort = true` to float the best fuzzy matches to the top.

With a preview the picker is a fixed fraction of the editor — the preview needs
the room whatever the items look like — and `width_ratio` buys the whole row, the
list and the preview taking half each. Without one the items decide: the list is
as wide as its widest label and as tall as it has items, clamped into the
`without_preview` bounds, so a two-item choice reads as a small menu rather than a
mostly empty picker. Both are measured once, over the full item list, so filtering
never resizes anything.

Every ratio is a fraction of the editor, and every one of them covers the whole
picker — `height_ratio` and `max_height_ratio` include the prompt above the list,
`width_ratio` includes the gap between the list and the preview. The exception is
`min_height_ratio`, which applies to the list alone. Where a minimum and a maximum
cross, the maximum wins.

## Keys

| Key | What it does |
| --- | --- |
| `<CR>` | Choose |
| `<Esc>` | Cancel |
| `<C-n>` / `<C-p>` (or `<Down>` / `<Up>`) | Move |
| `<C-d>` / `<C-u>` | Jump half a page |

## Previews

Callers opt into a preview with `preview_item`, this module's one extension over
`vim.ui.select`'s options (other implementations ignore it):

```lua
vim.ui.select(items, {
  prompt       = "Pick a buffer",
  format_item  = function(item) return item.name end,
  preview_item = function(item)
    return { buf = item.bufnr, pos = { item.lnum, 0 } }  -- pos is optional
  end,
}, on_choice)
```

The preview shows the **buffer** you hand back, as it currently is — so unsaved
changes, syntax and extmarks all appear.

---

[← All modules](../README.md#modules)
