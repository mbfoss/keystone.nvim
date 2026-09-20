# keystone.nvim

Quality-of-life editor modules for Neovim: file, symbol and call trees, a key-hint
popup, completion, a statusline, LSP and Treesitter setup, and editor behaviour
flags. Each module is independent, and none is active unless you name it in
`setup()`.

> **Requires Neovim ≥ 0.11.** No other plugins required.

## Installation <!-- tag: installation -->

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
  marksigns  = true,  -- shows the marks that are set in the sign column (0.12+)
  scope      = true,  -- guides along the current scope and indent levels
  animate    = false, -- interpolated scrolling

  -- Replaces something built in
  statusline = true,  -- sets 'statusline'
  select     = true,  -- replaces vim.ui.select
  notify     = true,  -- replaces vim.notify, adds :Notifications
  clue       = true,  -- popup of the keys that can follow a trigger

  -- Adds a command, does nothing until you run it
  filetree   = true,  -- :FileTree
  explore    = true,  -- :FileSelector
  symboltree = false, -- :SymbolTree
  calltree   = false, -- :CallTree
  unsaved    = false, -- :DiffUnsaved
  bufdelete  = false, -- :BDelete, :BWipeout, :BDeleteHidden, :BWipeoutHidden
})
```

Any other plugin manager works too; point it at `mbfoss/keystone.nvim` and call
`setup()` yourself.

The groups differ in how intrusive they are: the last only registers a command,
while "replaces something built in" takes over a global — turn those off if you
already have a statusline, `vim.notify` or key-hint plugin.

## Configuration <!-- tag: configuration -->

The table passed to `setup()` has one key per module. Modules you leave out stay
off. The value says how to turn the module on:

| Value | Meaning |
| --- | --- |
| `true` | Enable the module with its default options. |
| `{ ... }` | Enable the module, overriding only the options you name. |
| `false` | Leave the module off (same as omitting it). |

So `filetree = true` and `filetree = {}` are equivalent.

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

### Setting up a single module <!-- tag: single-module -->

`setup()` is a convenience wrapper. Every module is standalone and takes the same
options table directly:

```lua
require("keystone.filetree").setup({ width_ratio = 0.2 })
```

## Modules <!-- tag: modules -->

<!-- panvimdoc-ignore-start -->

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
| [lspconfig](docs/lspconfig.md) | Enables configured LSP servers, with log rotation |
| [tsconfig](docs/tsconfig.md) | Treesitter highlighting and folding, per buffer |
| [marksigns](docs/marksigns.md) | Shows the marks that are set in the sign column |
| [scope](docs/scope.md) | Guides along the current scope and indent levels |
| [largefile](docs/largefile.md) | Opens large files without Treesitter, LSP or ftplugins |
| [notify](docs/notify.md) | A floating notification UI |
| [select](docs/select.md) | A floating `vim.ui.select` prompt with fuzzy filtering |
| [unsaved](docs/unsaved.md) | Diff modified buffers against disk |
| [bufdelete](docs/bufdelete.md) | Delete or wipe buffers, keeping the window layout |
| [animate](docs/animate.md) | Interpolated scrolling |
| [tweaks](docs/tweaks.md) | Editor behaviour flags |

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
Each module has its own help page:

- |keystone-filetree| A file explorer in a side window
- |keystone-explore| A file selector for navigating the filesystem
- |keystone-calltree| The LSP call hierarchy of the symbol under the cursor
- |keystone-symboltree| The LSP document symbols of the current buffer
- |keystone-clue| A popup listing the keys that can follow a trigger
- |keystone-completion| LSP-driven autocompletion with `<Tab>`/`<CR>`
- |keystone-statusline| A statusline assembled from configurable sections
- |keystone-lspconfig| Enables configured LSP servers, with log rotation
- |keystone-tsconfig| Treesitter highlighting and folding, per buffer
- |keystone-marksigns| Shows the marks that are set in the sign column
- |keystone-scope| Guides along the current scope and indent levels
- |keystone-largefile| Opens large files without Treesitter, LSP or ftplugins
- |keystone-notify| A floating notification UI
- |keystone-select| A floating `vim.ui.select` prompt with fuzzy filtering
- |keystone-unsaved| Diff modified buffers against disk
- |keystone-bufdelete| Delete or wipe buffers, keeping the window layout
- |keystone-animate| Interpolated scrolling
- |keystone-tweaks| Editor behaviour flags
-->

## Commands <!-- tag: commands -->

Enabling the relevant module registers its command:

<!-- panvimdoc-ignore-start -->

| Command | Module | Purpose |
| --- | --- | --- |
| `:FileTree` | [filetree](docs/filetree.md) | Open the file-tree side window |
| `:FileSelector` | [explore](docs/explore.md) | Open the file selector |
| `:CallTree` | [calltree](docs/calltree.md) | Show the call hierarchy of the symbol under the cursor |
| `:SymbolTree` | [symboltree](docs/symboltree.md) | Toggle the document-symbol side window |
| `:Notifications` | [notify](docs/notify.md) | List or clear the notification history |
| `:DiffUnsaved` | [unsaved](docs/unsaved.md) | Diff unsaved buffers against disk |
| `:BDelete` `:BWipeout` `:BDeleteHidden` `:BWipeoutHidden` | [bufdelete](docs/bufdelete.md) | Delete or wipe buffers, keeping the window layout |

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
- `:FileTree` |keystone-filetree| Open the file-tree side window
- `:FileSelector` |keystone-explore| Open the file selector
- `:CallTree` |keystone-calltree| Show the call hierarchy of the symbol under
  the cursor
- `:SymbolTree` |keystone-symboltree| Toggle the document-symbol side window
- `:Notifications` |keystone-notify| List or clear the notification history
- `:DiffUnsaved` |keystone-unsaved| Diff unsaved buffers against disk
- `:BDelete` `:BWipeout` `:BDeleteHidden` `:BWipeoutHidden` |keystone-bufdelete|
  Delete or wipe buffers, keeping the window layout
-->

## Health <!-- tag: health -->

```vim
:checkhealth keystone
```

Reports the Neovim version, which modules are `active`/`inactive`, and per active
module the options changed from its defaults. Unrecognised option names are
warnings.

Some modules add a check of their own: `:checkhealth keystone.tsconfig` reports
installed parsers and missing queries.

## License <!-- tag: license -->

<!-- panvimdoc-ignore-start -->

[MIT](LICENSE). See [ATTRIBUTIONS.md](ATTRIBUTIONS.md) for third-party credits.

---

Contributing and internals: see [DEVELOPMENT.md](DEVELOPMENT.md).

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
MIT. See LICENSE and ATTRIBUTIONS.md in the repository for third-party credits.
-->
