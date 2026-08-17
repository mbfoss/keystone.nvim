# tsconfig

Treesitter highlighting and folding, switched on per-buffer whenever a parser
is available for the buffer's language.

![Treesitter folds following the syntax tree](https://github.com/mbfoss/keystone.nvim/releases/download/assets/tsconfig.gif)

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

## Relationship to nvim-treesitter

**This module is not a replacement for
[nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter), and it
does not install parsers.** The two solve adjacent problems and are normally
used together.

Three separate things have to line up before a buffer is highlighted by
treesitter, and each comes from somewhere different:

| Piece | Comes from | Notes |
| --- | --- | --- |
| The treesitter runtime (`vim.treesitter.start`, `foldexpr`) | **Neovim itself** | Built in |
| Parsers and queries per language | **nvim-treesitter**, or your own build | Neovim bundles only ~7 |
| *Turning it on for a buffer* | **this module** | What is otherwise left to you |

### What Neovim already does

Neovim ships parsers and queries for a small set of languages — `c`, `lua`,
`markdown`, `markdown_inline`, `query`, `vim`, `vimdoc` — and its own ftplugins
call `vim.treesitter.start()` for a subset of those: `lua`, `markdown`, `help`
and `query`. Everything else is left to you, *including languages whose parser
Neovim bundles*: open a `.c` file in a stock Neovim and you get regex syntax,
not treesitter, despite `c.so` being present.

### What nvim-treesitter does now

On its current `main` branch nvim-treesitter is deliberately narrow. It
describes itself as providing "functions for installing, updating, and removing
tree-sitter parsers" and "a collection of queries for enabling tree-sitter
features built into Neovim". The old module system — `require("nvim-treesitter.configs").setup({ highlight = { enable = true } })`
— is **gone**; highlighting and folding are Neovim's job now, and the README
tells you to call `vim.treesitter.start()` and set `foldexpr` yourself. (Its
legacy `master` branch still has the module system; `main` requires a newer
Neovim than keystone does.)

### What this module does

Exactly the step that fell out when that module system was removed. On
`FileType` it resolves the buffer's language, checks that a parser **and** the
relevant queries are present, and then starts highlighting and sets
`foldmethod`/`foldexpr` — per buffer, honouring `aliases` and `disable`.

The division:

```lua
-- nvim-treesitter: get the parsers and queries onto the runtimepath
require("nvim-treesitter").install({ "rust", "python", "tsx" })

-- keystone: turn them on for every buffer that has one
require("keystone").setup({ tsconfig = true })
```

If you already start treesitter yourself in an ftplugin or a `FileType`
autocmd, you do not need this module — it is that snippet, generalised.

### Notable behaviour

- **No parser, no change.** A language without a parser is left on regex syntax;
  nothing errors and nothing is installed for you. If a filetype looks
  un-highlighted, the parser is missing — install it with nvim-treesitter.
- **Queries are checked, not just parsers.** Starting treesitter with a parser
  but no `highlights` query colours nothing *and* switches regex syntax off,
  which is worse than leaving it alone. This module gates on the query being
  present, so a half-installed language degrades to plain regex syntax rather
  than to nothing.

---

[← All modules](../README.md#modules)
