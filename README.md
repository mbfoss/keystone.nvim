# keystone.nvim

A batteries-included set of editor modules for Neovim.

Keystone bundles the everyday essentials — a file tree, a which-key style hint
popup, completion, a statusline, sensible LSP and Treesitter setup, and a
handful of quality-of-life tweaks — into one small, dependency-free plugin.
Every module is self-contained and opt-in: you turn on only what you want, and
anything you don't mention is left untouched.

> **Requires Neovim ≥ 0.11.** No external plugins required.

> Looking for the fuzzy picker? It now lives in
> [ezpick.nvim](https://github.com/mbfoss/ezpick.nvim). See
> [Optional integrations](docs/integrations.md).

## Installation

Keystone works with any plugin manager, or with Neovim's built-in package
support.

**lazy.nvim**

```lua
{
  "mbfoss/keystone.nvim",
  config = function()
    require("keystone").setup({
      filetree = true,   -- see "Configuration" for what these values mean
      clue     = true,
    })
  end,
}
```

**Built-in packages** (`:help packages`)

```
git clone https://github.com/mbfoss/keystone.nvim \
  ~/.config/nvim/pack/plugins/opt/keystone.nvim
```

Then in your config:

```lua
vim.cmd.packadd("keystone.nvim")
require("keystone").setup({ filetree = true, clue = true })
```

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
  filetree  = { width_ratio = 0.25 },        -- on, with one option changed
  tweaks    = { highlight_on_yank = false }, -- on, with one option changed
  notify    = false,                         -- off (could also just omit it)
})
```

Each module's available options are documented on its own page under
[Modules](#modules) below.

### Setting up a single module

The `setup()` above is just a convenience wrapper. Every module is standalone,
so you can skip the wrapper and configure one directly — the table you pass is
that module's options (the same table you'd put after its key above):

```lua
require("keystone.filetree").setup({ width_ratio = 0.25 })
```

## Modules

Each module has its own page in [docs/](docs/):

| Module | What it gives you |
| --- | --- |
| [filetree](docs/filetree.md) | A file explorer in a side window |
| [explore](docs/explore.md) | A file selector for jumping around the filesystem |
| [calltree](docs/calltree.md) | The LSP call hierarchy of the symbol under the cursor |
| [symboltree](docs/symboltree.md) | The LSP document symbols of the current buffer |
| [clue](docs/clue.md) | A which-key style popup of follow-up keys |
| [completion](docs/completion.md) | LSP-driven autocompletion with `<Tab>`/`<CR>` |
| [statusline](docs/statusline.md) | A configurable statusline |
| [lspconfig](docs/lspconfig.md) | Sensible LSP defaults + log rotation |
| [tsconfig](docs/tsconfig.md) | Treesitter highlighting and folding |
| [bookmarks](docs/bookmarks.md) | Persistent, labelled line bookmarks |
| [largefile](docs/largefile.md) | Instant opening of very large files |
| [notify](docs/notify.md) | A floating notification UI |
| [select](docs/select.md) | A floating `vim.ui.select` prompt with fuzzy filtering |
| [unsaved](docs/unsaved.md) | Diff modified buffers against disk |
| [animate](docs/animate.md) | Smooth animated scrolling |
| [tweaks](docs/tweaks.md) | Quality-of-life editor behaviours |

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

## Optional integrations

Keystone picks up [ezpick.nvim](https://github.com/mbfoss/ezpick.nvim)
automatically when it is installed, and works fine without it. See
[docs/integrations.md](docs/integrations.md) — including notes on migrating from
the old `keystone.pick`.

## Full option reference

The module pages cover the common cases. For the complete, authoritative list,
each module documents every field as a `Config` class annotation near the top of
its file (`lua/keystone/<module>.lua`).

## License

[MIT](LICENSE). See [ATTRIBUTIONS.md](ATTRIBUTIONS.md) for third-party credits.

---

Looking to contribute or understand how Keystone is built? See
[DEVELOPMENT.md](DEVELOPMENT.md).
