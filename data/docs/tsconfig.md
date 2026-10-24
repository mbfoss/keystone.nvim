# tsconfig

Treesitter highlighting and folding, switched on per-buffer whenever a parser
is available for the buffer's language.

<!-- panvimdoc-ignore-start -->

![Treesitter folds following the syntax tree](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/tsconfig.gif)

<!-- panvimdoc-ignore-end -->

## Configuration <!-- tag: configuration -->

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

## Relationship to nvim-treesitter <!-- tag: relationship -->

**This module is not a replacement for
[nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter), and it
does not install parsers.** The two are normally used together.

Three things have to line up before a buffer is highlighted by treesitter:

| Piece | Comes from | Notes |
| --- | --- | --- |
| The treesitter runtime (`vim.treesitter.start`, `foldexpr`) | **Neovim itself** | Built in |
| Parsers and queries per language | **nvim-treesitter**, or your own build | Neovim bundles only ~7 |
| *Turning it on for a buffer* | **this module** | What is otherwise left to you |

### What Neovim already does <!-- tag: neovim -->

Neovim ships parsers and queries for `c`, `lua`, `markdown`,
`markdown_inline`, `query`, `vim` and `vimdoc`, but its ftplugins call
`vim.treesitter.start()` only for `lua`, `markdown`, `help` and `query`. The rest
is left to you, *including bundled parsers*: a `.c` file in a stock Neovim gets
regex syntax despite `c.so` being present.

### What nvim-treesitter does now <!-- tag: upstream -->

On its `main` branch nvim-treesitter installs parsers and ships queries, and
nothing else. The old module system,
`require("nvim-treesitter.configs").setup({ highlight = { enable = true } })`, is
**gone**; its README tells you to call `vim.treesitter.start()` and set
`foldexpr` yourself. (The legacy `master` branch still has the module system;
`main` requires a newer Neovim than keystone does.)

### What this module does <!-- tag: module -->

Exactly the step that fell out when that module system was removed. On
`FileType` it resolves the buffer's language, checks that a parser **and** the
relevant queries are present, then starts highlighting and sets
`foldmethod`/`foldexpr`, honouring `aliases` and `disable`.

```lua
-- nvim-treesitter: get the parsers and queries onto the runtimepath
require("nvim-treesitter").install({ "rust", "python", "tsx" })

-- keystone: turn them on for every buffer that has one
require("keystone").setup({ tsconfig = true })
```

If you already start treesitter yourself in an ftplugin or a `FileType`
autocmd, you do not need this module; it is that snippet, generalised.

### Notable behaviour <!-- tag: behaviour -->

- **No parser, no change.** A language without a parser is left on regex syntax;
  nothing errors and nothing is installed. If a filetype looks un-highlighted,
  install its parser with nvim-treesitter.
- **Queries are checked, not just parsers.** A parser with no `highlights` query
  colours nothing *and* switches regex syntax off, so this module gates on the
  query being present: a half-installed language degrades to regex syntax rather
  than to nothing.

<!-- panvimdoc-ignore-start -->

---

[← All modules](../README.md#modules)

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
All modules: |keystone-modules|
-->
