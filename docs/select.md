# select

Replaces `vim.ui.select` — the prompt Neovim shows whenever something asks you
to choose from a list (LSP code actions, `:Bookmark pick`, `:DiffUnsaved`, other
plugins) — with a floating one: a prompt line, a fuzzy-filtered list, and a
preview window for callers that offer one.

![A vim.ui.select prompt with fuzzy filtering and a live preview](assets/select.gif)

## Configuration

```lua
require("keystone").setup({
  select = {
    width_ratio  = 0.4,   -- fraction of the editor width the list occupies (a minimum, without a preview)
    height_ratio = 0.7,   -- fraction of the editor height the picker occupies
    sort         = false, -- order filtered items by fuzzy score, not the caller's order
  },
})
```

Filtering keeps the caller's order by default, so items stay where you last saw
them as you type; set `sort = true` to float the best fuzzy matches to the top.

Without a preview the prompt shrinks to fit its items, so a two-item choice
reads as a small menu rather than a picker.

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
