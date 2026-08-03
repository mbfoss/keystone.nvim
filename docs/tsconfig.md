# tsconfig

Treesitter highlighting and folding, switched on per-buffer whenever a parser
is available for the buffer's language.

## Configuration

```lua
require("keystone").setup({
  tsconfig = {
    highlight = true,
    fold      = true,   -- foldmethod=expr using the Treesitter foldexpr
    fold_open = true,   -- start with all folds open
    aliases   = {},     -- map a filetype to a parser, e.g. { typescriptreact = "tsx" }
    disable   = {},     -- languages to skip: a list, or a predicate(lang, bufnr)
    -- on_attach = function(bufnr, lang) ... end,
  },
})
```

---

[← All modules](../README.md#modules)
