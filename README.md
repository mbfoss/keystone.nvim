# keystone.nvim

A quality-of-life Neovim plugin. It bundles a set of independent features —
a fuzzy picker, file tree, LSP and Treesitter setup, notifications, a
statusline, a which-key style popup, and more — that can each be enabled and
configured on their own.

## Requirements

- Neovim >= 0.10
- [ripgrep](https://github.com/BurntSushi/ripgrep) for the file and grep pickers
- A Nerd Font (optional, for icons)

## Installation

Every feature is a separate module with its own `setup`. There is no global
`require("keystone").setup()`; enable only the modules you want.

With the built-in package manager (`vim.pack`, Neovim >= 0.12):

```lua
vim.pack.add({
  { src = "https://github.com/mbfoss/keystone.nvim" },
})

require("keystone.pick").setup()
require("keystone.filetree").setup()
require("keystone.lspconfig").setup()
require("keystone.tsconfig").setup()
require("keystone.notify").setup()
require("keystone.statusline").setup()
require("keystone.clue").setup()
require("keystone.tweaks").setup()
```

To update or remove the plugin later:

```vim
:lua vim.pack.update()
:lua vim.pack.del({ "keystone.nvim" })
```

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "mbfoss/keystone.nvim",
  config = function()
    require("keystone.pick").setup()
    require("keystone.filetree").setup()
    require("keystone.lspconfig").setup()
    require("keystone.tsconfig").setup()
    require("keystone.notify").setup()
    require("keystone.statusline").setup()
    require("keystone.clue").setup()
    require("keystone.tweaks").setup()
  end,
}
```

As a native package (Neovim >= 0.10):

```sh
git clone https://github.com/mbfoss/keystone.nvim \
  ~/.config/nvim/pack/plugins/opt/keystone.nvim
```

```lua
vim.cmd.packadd("keystone.nvim")
require("keystone.pick").setup()
-- ...other modules
```

## Features

| Module        | Command         | Description                                                                 |
|---------------|-----------------|-----------------------------------------------------------------------------|
| `pick`        | `:Pick`         | Floating async fuzzy picker; can override `vim.ui.select`                    |
| `filetree`    | `:FileTree`     | Sidebar file tree                                                           |
| `explore`     | `:FileSelector` | Floating file explorer / selector                                          |
| `bookmarks`   | `:Bookmark`     | Named, persistent line bookmarks with signs                                |
| `lspconfig`   | `:Lsp`          | Auto-enable LSP servers, diagnostics, format-on-save, inlay hints          |
| `tsconfig`    | —               | Auto-start Treesitter highlighting and folds per filetype                  |
| `notify`      | —               | Replaces `vim.notify` with floating notifications and LSP progress         |
| `complete`    | —               | Lightweight LSP completion with optional Tab-to-accept                      |
| `statusline`  | —               | Statusline: mode, git, filename, diagnostics, filetype, position           |
| `clue`        | —               | which-key style popup of follow-up keys for trigger prefixes               |
| `animate`     | —               | Scroll and cursor animation                                                |
| `tweaks`      | —               | Small editor quality-of-life behaviours                                    |

## Modules

Each `setup(opts)` merges `opts` with the module defaults. The options below
are the most common; see the type annotations in each module for the full set.

### pick

Fuzzy picker for files, grep, buffers, LSP results, and more. By default it
also overrides `vim.ui.select`.

```lua
require("keystone.pick").setup({
  override_ui_select = true,
})
```

Usage: `:Pick <type> [query]`, e.g. `:Pick files` or `:Pick live_grep word`.
Available types:

```
files            recent_files     config_files     live_grep
buffers          windows          jumplist
quickfix         keymaps          commands         autocommands
highlights       notifications    spell_suggest
lsp_references   document_symbols
document_diagnostics    workspace_diagnostics
```

### filetree

Sidebar file tree. Usage: `:FileTree <subcommand>` (Tab-completed).

```lua
require("keystone.filetree").setup({
  width_ratio = 0.2,
})
```

### explore

Floating file explorer and selector. Usage: `:FileSelector <subcommand>`.

```lua
require("keystone.explore").setup()
```

### bookmarks

Named, persistent line bookmarks shown in the sign column. Usage:
`:Bookmark <subcommand>`.

```lua
require("keystone.bookmarks").setup({
  persist_dir = nil,      -- defaults to vim.fn.stdpath("data")
  sign_text   = "",
})
```

### lspconfig

Enables LSP servers found in your `lsp/` runtime directories and wires up
diagnostics, formatting, inlay hints, and document highlighting. Usage:
`:Lsp <subcommand>`.

```lua
require("keystone.lspconfig").setup({
  servers     = "all",          -- or a list of server names
  auto_enable = true,
  format      = { on_save = false, timeout_ms = 2000 },
  inlay_hints = false,
  document_highlight = false,
  settings    = {
    -- lua_ls = { settings = { ... } },
  },
  on_attach   = function(client, bufnr) end,
})
```

### tsconfig

Starts Treesitter highlighting and folds on `FileType` for buffers whose
language has a parser installed.

```lua
require("keystone.tsconfig").setup({
  highlight = true,
  fold      = true,
  fold_open = true,
  aliases   = { typescriptreact = "tsx" },
  disable   = {},               -- list of languages or a predicate
})
```

Diagnose with `:checkhealth keystone.tsconfig`.

#### Relationship to nvim-treesitter

This module does **not** install or compile parsers — it only activates the
parsers already on your `runtimepath`. Neovim core ships a handful (c, lua,
vim, vimdoc, markdown, query, ...) and auto-starts highlighting for them; for
anything else you still need a parser source such as
[nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) to
download and build it (`:TSInstall <lang>`).

So it is **not** a drop-in replacement for nvim-treesitter; how the two relate
depends on which branch you run:

- **nvim-treesitter `main` (the rewrite)** — complementary. That branch
  installs parsers and nothing else: it deliberately dropped the old
  highlight/fold/indent modules and expects you to call `vim.treesitter.start()`
  and set `foldexpr` yourself. `tsconfig` *is* that wiring, generalized to any
  installed parser and hardened against the usual traps (parser present but no
  `highlights` query, ABI-mismatched parsers, window-local fold leakage).
  Use nvim-treesitter to install parsers, `tsconfig` to turn them on.
- **nvim-treesitter `master` (classic)** — overlapping. Its
  `configs.setup({ highlight = { enable = true }, fold = ... })` already enables
  highlighting and folds, so running both duplicates the `FileType`/highlight
  handling. Pick one: either the classic modules **or** `tsconfig`, not both.

In short: keep `tsconfig` if you are on (or moving to) the `main` rewrite;
disable it if you rely on classic nvim-treesitter's highlight/fold modules.

### notify

Replaces `vim.notify` with floating notifications and optional LSP progress.

```lua
require("keystone.notify").setup({
  width         = 0.3,          -- fraction of editor width
  border        = "rounded",
  timeout       = 3000,
  lsp_progress  = false,
  history_limit = 100,
})
```

### complete

Lightweight LSP completion. Optionally maps `<Tab>` / `<S-Tab>` to accept the
selected item, falling back to their normal action when no menu is open.

```lua
require("keystone.complete").setup({
  delay          = 100,
  key            = "<C-Space>",
  tab_completion = true,
})
```

### statusline

```lua
require("keystone.statusline").setup({
  sections = {
    left  = { "mode", "git", "filename" },
    right = { "lsp_progress", "diagnostics", "filetype", "position" },
  },
})
```

Custom sections can be registered as named providers or inline functions.

### clue

which-key style popup of follow-up keys. After a trigger prefix is pressed,
a popup of available continuations appears after a short delay; the resolved
sequence is then re-fed so the real mapping runs natively.

```lua
require("keystone.clue").setup({
  delay   = 300,
  border  = "rounded",
  preset  = true,                -- builtin g/z/window descriptions
  builtin = { marks = true, registers = true },
})

-- Add group labels:
require("keystone.clue").add({
  { mode = "n", keys = "<leader>f", desc = "Find", group = true },
})
```

Default triggers are limited to safe prefix keys (`<leader>`, `g`, `z`, marks,
registers, `[`, `]`, `<C-w>`, ...).

### animate

```lua
require("keystone.animate").setup({
  speed    = 20,                 -- ms per line
  duration = 300,                -- hard cap, ms
})
```

### tweaks

A collection of small editor behaviours, each toggled independently.

```lua
require("keystone.tweaks").setup({
  highlight_on_yank    = true,
  restore_cursor       = true,
  auto_create_dir      = true,
  auto_reload          = true,
  equalize_splits      = true,
  quick_close          = false,  -- close help/qf/etc. with `q`
  disable_auto_comment = false,
  trim_whitespace      = false,
})
```

## Commands

| Command                 | Provided by | Description                          |
|-------------------------|-------------|--------------------------------------|
| `:Pick <type> [query]`  | `pick`      | Open a picker                        |
| `:FileTree <cmd>`       | `filetree`  | Control the file tree window         |
| `:FileSelector <cmd>`   | `explore`   | Open the floating file explorer      |
| `:Bookmark <cmd>`       | `bookmarks` | Manage bookmarks                     |
| `:Lsp <cmd>`            | `lspconfig` | Manage LSP servers and behaviour     |

All subcommanded commands support Tab completion.

## Testing

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s busted
runner and live in `tests/`.

```sh
make test

# With a custom plenary checkout:
NVIM_PLENARY_DIR=/path/to/plenary.nvim make test
```

If `NVIM_PLENARY_DIR` is not set, plenary is cloned into `/tmp/plenary.nvim`
automatically.

## License

MIT. See [LICENSE](LICENSE).
