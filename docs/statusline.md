# statusline

A statusline assembled from named sections, each of which is a built-in, a
registered provider, or an inline function.

![The sections reacting: mode, git branch, symbol path, diagnostics, position](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/statusline.gif)

## Configuration

```lua
require("keystone").setup({
  statusline = {
    sections = {
      left  = { "mode", "git", "filename" },
      right = { "lsp_progress", "diagnostics", "filetype", "position" },
    },
  },
})
```

## Sections

Built-in sections are `mode`, `git`, `filename`, `diagnostics`, `filetype`,
`position`, and `lsp_progress`.

A section can also be an inline function returning a statusline string:

```lua
statusline = {
  sections = {
    right = { function() return "%l:%c" end },
  },
}
```

## API

Register a named provider so it can be used by name in `sections`:

```lua
require("keystone.statusline").register(name, provider)
```

---

[← All modules](../README.md#modules)
