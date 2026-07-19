# keystone.nvim

A batteries-included set of editor modules for Neovim.

Keystone bundles the everyday essentials — a fuzzy picker, a file tree, a
which-key style hint popup, completion, a statusline, sensible LSP and
Treesitter setup, and a handful of quality-of-life tweaks — into one small,
dependency-free plugin. Every module is self-contained and opt-in: you turn on
only what you want, and anything you don't mention is left untouched.

> **Requires Neovim ≥ 0.11.** No external plugins required.

## Installation

Keystone works with any plugin manager, or with Neovim's built-in package
support.

**lazy.nvim**

```lua
{
  "mbfoss/keystone.nvim",
  config = function()
    require("keystone").setup({
      pick     = true,   -- see "Configuration" for what these values mean
      filetree = true,
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
require("keystone").setup({ pick = true, filetree = true })
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

So these two are equivalent — both enable `pick` with its defaults:

```lua
require("keystone").setup({ pick = true })
require("keystone").setup({ pick = {} })
```

A fuller example:

```lua
require("keystone").setup({
  pick      = true,                          -- on, with defaults
  filetree  = { width_ratio = 0.25 },        -- on, with one option changed
  tweaks    = { highlight_on_yank = false }, -- on, with one option changed
  notify    = false,                         -- off (could also just omit it)
})
```

Each module's available options are listed under [Modules](#modules) below.

### Setting up a single module

The `setup()` above is just a convenience wrapper. Every module is standalone,
so you can skip the wrapper and configure one directly — the table you pass is
that module's options (the same table you'd put after its key above):

```lua
require("keystone.pick").setup({ override_ui_select = true })
```

## Modules

At a glance:

| Module | What it gives you |
| --- | --- |
| [pick](#pick) | Fuzzy picker for files, grep, buffers, symbols, and more |
| [filetree](#filetree) | A file explorer in a side window |
| [explore](#explore) | A file selector for jumping around the filesystem |
| [clue](#clue) | A which-key style popup of follow-up keys |
| [completion](#completion) | LSP-driven autocompletion with `<Tab>`/`<CR>` |
| [statusline](#statusline) | A configurable statusline |
| [lspconfig](#lspconfig) | Sensible LSP defaults + log rotation |
| [tsconfig](#tsconfig) | Treesitter highlighting and folding |
| [bookmarks](#bookmarks) | Persistent, labelled line bookmarks |
| [largefile](#largefile) | Instant opening of very large files |
| [notify](#notify) | A floating notification UI |
| [unsaved](#unsaved) | Diff modified buffers against disk |
| [animate](#animate) | Smooth animated scrolling |
| [tweaks](#tweaks) | Quality-of-life editor behaviours |

Every option below can be passed in the module's setup table. Passing `true`
uses the defaults shown; passing a table overrides individual fields.

### pick

A fast, dependency-free fuzzy picker. It ships a broad set of built-in sources
and can optionally take over `vim.ui.select`.

```lua
pick = {
  override_ui_select = true, -- route vim.ui.select through the picker
}
```

Open a source with the `:Pick` command:

```vim
:Pick files
:Pick live_grep
:Pick buffers
```

Built-in sources include `files`, `live_grep`, `recent_files`, `config_files`,
`buffers`, `windows`, `quickfix`, `loclist`, `jumplist`, `lsp_references`,
`document_symbols`, `document_diagnostics`, `workspace_diagnostics`, `keymaps`,
`commands`, `autocommands`, `highlights`, `notifications`, and `spell_suggest`.
Inside a picker, `g?` shows the available keys. You can register your own
sources with `require("keystone.pick").register(name, spec)`.

### filetree

A file explorer that lives in a side window.

```lua
filetree = {
  width_ratio = 0.2,             -- fraction of the editor width
  follow_current_buffer = false, -- reveal the current file as you switch buffers
}
```

Control it with `:FileTree [open|close|toggle]` (no argument toggles).

### explore

A lightweight file selector for jumping around the filesystem. Enable it and
open the selector with `:FileSelector`.

```lua
explore = true
```

### clue

A which-key style popup that shows the available continuation keys a short
moment after you press a trigger (`<leader>`, `g`, `z`, marks, registers,
window commands, and more).

```lua
clue = {
  delay = 300,          -- ms before the popup appears
  border = "rounded",
  max_desc_width = 40,  -- crop long descriptions with …
  preset = true,        -- register built-in g/z/window descriptions
  builtin = { marks = true, registers = true },
  -- triggers = { ... } -- override the default trigger list if you like
}
```

Add your own group/label descriptions with `require("keystone.clue").add(...)`.

### completion

A source-agnostic autocompletion engine. It decides *when* to complete
(autotrigger or the manual key) and fires the sources in `source_order`; on
Neovim ≥ 0.11 the `omnifunc` source is the built-in `vim.lsp.completion`.

```lua
completion = {
  delay          = 100,           -- debounce before autotriggering, in ms
  key            = "<C-Space>",   -- manual trigger (insert mode)
  tab_completion = true,          -- <Tab>/<S-Tab> confirm + snippet navigation
  cr_confirm     = true,          -- <CR> confirms the current candidate
  source_order   = { "completefunc", "omnifunc" },
}
```

### statusline

A configurable statusline assembled from pluggable sections.

```lua
statusline = {
  sections = {
    left  = { "mode", "git", "filename" },
    right = { "lsp_progress", "diagnostics", "filetype", "position" },
  },
}
```

Built-in sections are `mode`, `git`, `filename`, `diagnostics`, `filetype`,
`position`, and `lsp_progress`. A section can also be an inline function
returning a statusline string, and you can register named providers with
`require("keystone.statusline").register(name, provider)`.

### lspconfig

Sensible LSP defaults on top of Neovim's built-in `vim.lsp` — most importantly,
it actually *enables* your configured servers, which vanilla Neovim leaves to
you.

```lua
lspconfig = {
  servers    = "all",  -- "all" enables every config found in lsp/ dirs, or a list of names
  auto_enable = true,
  format = { on_save = false, async = false, timeout_ms = 2000 },
  inlay_hints        = true,
  document_highlight = true,  -- highlight references of the symbol under the cursor
  signature_help     = true,  -- signature help float while typing
  lsp_rolling_log    = true,  -- cap the ever-growing lsp.log (true, false, or { max_bytes, keep })
  -- diagnostics   = { ... }, -- passed straight to vim.diagnostic.config
  -- settings      = { lua_ls = { settings = {...} } }, -- per-server overrides
  -- capabilities  = ..., on_attach = function(client, bufnr) ... end,
}
```

### tsconfig

Treesitter highlighting and folding, switched on per-buffer whenever a parser
is available for the buffer's language.

```lua
tsconfig = {
  highlight = true,
  fold      = true,   -- foldmethod=expr using the Treesitter foldexpr
  fold_open = true,   -- start with all folds open
  aliases   = {},     -- map a filetype to a parser, e.g. { typescriptreact = "tsx" }
  disable   = {},     -- languages to skip: a list, or a predicate(lang, bufnr)
  -- on_attach = function(bufnr, lang) ... end,
}
```

### bookmarks

Persistent, optionally labelled line bookmarks that survive across sessions.

```lua
bookmarks = {
  persist_path = nil,               -- bookmarks file; nil = ~/.nvimbookmarks
  sign_text    = "*",
  sign_hl      = "DiagnosticInfo",
}
```

Manage them with `:Bookmark <sub>`, where `<sub>` is one of `set`, `setlabel`,
`delete`, `pick`, `list`, `clear_file`, or `clear_all`.

### largefile

Opens very large files instantly. Instead of tearing down Treesitter/LSP/
ftplugins after a big file loads, it detects the file during filetype detection
and gives it a sentinel filetype so none of that machinery ever attaches.

```lua
largefile = {
  size_threshold   = 1024 * 1024, -- bytes above which a file is treated as large
  keep_syntax      = true,        -- restore cheap regex syntax for the real filetype
  disable_folding  = true,
  disable_swapfile = true,
  disable_undofile = true,
  notify           = false,       -- announce when a buffer opens in fast mode
}
```

### notify

A floating notification UI, optionally including LSP progress messages.

```lua
notify = {
  width        = 0.3,        -- fraction of the editor width
  border       = "rounded",
  timeout      = 3000,
  lsp_progress = false,      -- surface LSP progress as notifications
  lsp_progress_delay = 1000, -- skip progress for short-lived tasks
  history_limit = 100,
}
```

### unsaved

Diff every modified buffer against its saved state on disk. Enable it and run
`:DiffUnsaved`.

```lua
unsaved = true
```

### animate

Smooth animated scrolling.

```lua
animate = {
  speed    = 20,  -- ms per line
  duration = 300, -- hard cap on animation length, in ms
  step     = 16,  -- frame interval in ms
  -- filter = function(buf) ... end, -- return false to skip a buffer
  -- easing = function(i) ... end,
}
```

### tweaks

A collection of quality-of-life editor behaviours. Each is an independent flag,
so you can enable exactly the ones you want.

```lua
tweaks = {
  highlight_on_yank    = true,  -- briefly highlight yanked text
  restore_cursor       = true,  -- jump to last cursor position when reopening a file
  auto_create_dir      = true,  -- create missing parent directories on save
  auto_reload          = true,  -- reload files changed outside Neovim
  quick_close          = false, -- close help/qf/man/... buffers with q
  disable_auto_comment = false, -- stop auto-continuing comment leaders
  trim_whitespace      = false, -- strip trailing whitespace on save
}
```

## Commands

Enabling the relevant module registers its command:

| Command | Module | Purpose |
| --- | --- | --- |
| `:Pick` | pick | Open a picker (files, grep, buffers, …) |
| `:FileTree` | filetree | Toggle the file-tree side window |
| `:FileSelector` | explore | Open the file selector |
| `:Bookmark` | bookmarks | Manage line bookmarks |
| `:DiffUnsaved` | unsaved | Diff unsaved buffers against disk |

## Full option reference

The options documented above cover the common cases. For the complete,
authoritative list, each module documents every field as a `Config` class
annotation near the top of its file (`lua/keystone/<module>.lua`).

## License

[MIT](LICENSE). See [ATTRIBUTIONS.md](ATTRIBUTIONS.md) for third-party credits.

---

Looking to contribute or understand how Keystone is built? See
[DEVELOPMENT.md](DEVELOPMENT.md).
