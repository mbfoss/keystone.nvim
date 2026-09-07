# statusline

A statusline assembled from named sections, each of which is a built-in, a
registered provider, or an inline function.

<!-- panvimdoc-ignore-start -->

![The sections reacting: mode, git branch, symbol path, diagnostics, position](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/statusline.gif)

<!-- panvimdoc-ignore-end -->

## Configuration <!-- tag: configuration -->

```lua
require("keystone").setup({
  statusline = {
    sections = {
      left  = { "mode", "filename" },
      right = { "lsp_progress", "diagnostics", "filetype", "position" },
    },
  },
})
```

## Sections <!-- tag: sections -->

Default sections: `mode`, `filename`, `diagnostics`, `filetype`, `position`,
`lsp_progress`. Opt-in: `git` (current branch) and `symbol_path` (the LSP symbol
under the cursor).

A section can also be an inline function returning a statusline string:

```lua
statusline = {
  sections = {
    right = { function() return "%l:%c" end },
  },
}
```

## API <!-- tag: api -->

Register a named provider so it can be used by name in `sections`:

```lua
require("keystone.statusline").register(name, provider)
```

<!-- panvimdoc-ignore-start -->

---

[← All modules](../README.md#modules)

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
All modules: |keystone-modules|
-->
