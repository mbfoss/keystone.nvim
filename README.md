# keystone.nvim

Seventeen editor modules for Neovim: file, symbol and call trees, a key-hint
popup, completion, a statusline, LSP and Treesitter setup, and a set of editor
behaviour flags.

Each module is independent — it can be required and configured on its own — and
none is active unless you name it in `setup()`.

> **Requires Neovim ≥ 0.11.** No other plugins required.

## Installation

With Neovim ≥ 0.12

```lua
vim.pack.add({ "https://github.com/mbfoss/keystone.nvim" })

-- Every module, with a starting point for which to enable. Flip any of these.
require("keystone").setup({
  -- Language support
  lspconfig  = true,  -- enables the LSP servers configured in lsp/
  tsconfig   = true,  -- treesitter highlighting and folding
  completion = true,  -- drives insert-mode completion

  -- Editor behaviour
  tweaks     = true,  -- Behaviour tweaks (yank highlight, cursor restore, ...)
  largefile  = true,  -- skips treesitter/LSP/ftplugins on large files
  animate    = false, -- interpolated scrolling

  -- Replaces something built in
  statusline = true,  -- sets 'statusline'
  select     = true,  -- replaces vim.ui.select
  notify     = true,  -- replaces vim.notify
  clue       = true,  -- popup of the keys that can follow a trigger

  -- Adds a command, does nothing until you run it
  filetree   = true,  -- :FileTree
  explore    = true,  -- :FileSelector
  symboltree = false, -- :SymbolTree
  calltree   = false, -- :CallTree
  bookmarks  = false, -- :Bookmark
  unsaved    = false, -- :DiffUnsaved
  bufdelete  = false, -- :Bdelete, :Bwipeout, :Bdeletehidden, :Bwipeouthidden
})
```

Any other plugin manager works too — just point it at
`mbfoss/keystone.nvim` and call `setup()` yourself.

Installing only puts keystone on the runtimepath; the `setup()` call is what
decides which modules run. The four groups differ in how intrusive they are: the
last group only registers a command, while the "replaces something built in"
group takes over a global, so those are the ones to turn off if you already have
a statusline, a `vim.notify` or a key-hint plugin of your own.

## Configuration

You configure Keystone with a single `setup()` call. The table you pass has one
**key per module** you want to turn on. Nothing is enabled unless you list it —
modules you leave out stay off.

The **value** you give a module says *how* to turn it on:

| Value | Meaning |
| --- | --- |
| `true` | Enable the module with its default options. |
| `{ ... }` | Enable the module, overriding only the options you name. |
| `false` | Leave the module off (same as omitting it). |

So these two are equivalent — both enable `filetree` with its defaults:

```lua
require("keystone").setup({ filetree = true })
require("keystone").setup({ filetree = {} })
```

A fuller example:

```lua
require("keystone").setup({
  clue      = true,                          -- on, with defaults
  filetree  = { width_ratio = 0.2 },        -- on, with one option changed
  tweaks    = { highlight_on_yank = false }, -- on, with one option changed
  notify    = false,                         -- off (could also just omit it)
})
```

Each module's available options are documented on its own page under
[Modules](#modules) below.

### Setting up a single module

The `setup()` above is a convenience wrapper. Every module is standalone, so it
can be configured directly instead — the table you pass is that module's
options, the same table that would follow its key above:

```lua
require("keystone.filetree").setup({ width_ratio = 0.2 })
```

## Modules

Each module has its own page in [docs/](docs/):

| Module | What it does |
| --- | --- |
| [filetree](docs/filetree.md) | A file explorer in a side window |
| [explore](docs/explore.md) | A file selector for navigating the filesystem |
| [calltree](docs/calltree.md) | The LSP call hierarchy of the symbol under the cursor |
| [symboltree](docs/symboltree.md) | The LSP document symbols of the current buffer |
| [clue](docs/clue.md) | A popup listing the keys that can follow a trigger |
| [completion](docs/completion.md) | LSP-driven autocompletion with `<Tab>`/`<CR>` |
| [statusline](docs/statusline.md) | A statusline assembled from configurable sections |
| [lspconfig](docs/lspconfig.md) | Enables configured LSP servers; per-server defaults and log rotation |
| [tsconfig](docs/tsconfig.md) | Treesitter highlighting and folding, per buffer |
| [bookmarks](docs/bookmarks.md) | Persistent, optionally labelled line bookmarks |
| [largefile](docs/largefile.md) | Opens files over a size threshold without Treesitter/LSP/ftplugins |
| [notify](docs/notify.md) | A floating notification UI |
| [select](docs/select.md) | A floating `vim.ui.select` prompt with fuzzy filtering |
| [unsaved](docs/unsaved.md) | Diff modified buffers against disk |
| [bufdelete](docs/bufdelete.md) | Delete or wipe buffers without disturbing the window layout |
| [animate](docs/animate.md) | Interpolated scrolling |
| [tweaks](docs/tweaks.md) | Seven editor behaviour flags |

## Commands

Enabling the relevant module registers its command:

| Command | Module | Purpose |
| --- | --- | --- |
| `:FileTree` | [filetree](docs/filetree.md) | Toggle the file-tree side window |
| `:FileSelector` | [explore](docs/explore.md) | Open the file selector |
| `:CallTree` | [calltree](docs/calltree.md) | Show the call hierarchy of the symbol under the cursor |
| `:SymbolTree` | [symboltree](docs/symboltree.md) | Toggle the document-symbol side window |
| `:Bookmark` | [bookmarks](docs/bookmarks.md) | Manage line bookmarks |
| `:DiffUnsaved` | [unsaved](docs/unsaved.md) | Diff unsaved buffers against disk |
| `:Bdelete` `:Bwipeout` `:Bdeletehidden` `:Bwipeouthidden` | [bufdelete](docs/bufdelete.md) | Delete or wipe buffers, keeping the window layout |

## Optional integrations

Keystone detects [ezpick.nvim](https://github.com/mbfoss/ezpick.nvim) when it is
installed and registers two picker sources with it; without it, those sources
are absent and nothing else differs. See
[docs/integrations.md](docs/integrations.md).

## Full option reference

The module pages cover the common cases. For the complete, authoritative list,
each module documents every field as a `Config` class annotation near the top of
its file (`lua/keystone/<module>.lua`).

## License

[MIT](LICENSE). See [ATTRIBUTIONS.md](ATTRIBUTIONS.md) for third-party credits.

---

Contributing and internals: see [DEVELOPMENT.md](DEVELOPMENT.md).
