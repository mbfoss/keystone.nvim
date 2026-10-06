# keystone.nvim

> [!NOTE]
> **Work in progress.** Stable and usable as it stands, but still evolving:
> changes, including breaking ones, can land at any time. Pin a commit if you
> need a fixed target.

Quality-of-life editor modules for Neovim: file, symbol and call trees, a key-hint
popup, completion, a statusline, LSP and Treesitter setup, and editor behaviour
flags. Each module is independent, and none is active unless you name it in
`setup()`.

> **Requires Neovim >= 0.11.** No other plugins required.

## Installation <!-- tag: installation -->

With Neovim >= 0.12

```lua
vim.pack.add({ "https://github.com/mbfoss/keystone.nvim" })

-- Every module, with a starting point for which to enable. Flip any of these.
require("keystone").setup({
  -- Language support
  lspsetup    = true,  -- LSP defaults; nothing starts until named, e.g.
                       -- lspsetup = { servers = { "lua_ls" } }
  tsconfig    = true,  -- treesitter highlighting and folding
  completion  = true,  -- drives insert-mode completion

  -- Editor behaviour
  tweaks      = true,  -- Behaviour tweaks (yank highlight, cursor restore, ...)
  largefile   = true,  -- skips treesitter/LSP/ftplugins on large files
  marksigns   = true,  -- shows the marks that are set in the sign column (0.12+)
  scope       = true,  -- guides along the current scope and indent levels
  animate     = false, -- interpolated scrolling

  -- Replaces something built in
  statusline  = true,  -- sets 'statusline'
  select      = true,  -- replaces vim.ui.select
  notify      = true,  -- replaces vim.notify, adds :Notifications
  clue        = true,  -- popup of the keys that can follow a trigger

  -- Adds a command, does nothing until you run it
  filetree    = true,  -- :FileTree
  explore     = true,  -- :FileSelector
  symboltree  = false, -- :SymbolTree
  calltree    = false, -- :CallTree
  diffunsaved = false, -- :DiffUnsaved
  bufdelete   = false, -- :BDelete, :BWipeout, :BDeleteHidden, :BWipeoutHidden
})
```

Any other plugin manager works too; point it at `mbfoss/keystone.nvim` and call
`setup()` yourself.

The groups differ in how intrusive they are: the last only registers a command,
while "replaces something built in" takes over a global: turn those off if you
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

The same thing with every module expanded to its options:

```lua
require("keystone").setup({
  -- Language support
  lspsetup = {
    servers     = {},  -- names of the servers to enable, e.g. { "lua_ls", "pyright" }.
                       -- Nothing is enabled unless named.
    auto_enable = true,
    format = { on_save = false, async = false, timeout_ms = 2000 },
    inlay_hints        = true,
    document_highlight = true,  -- highlight references of the symbol under the cursor
    signature_help     = true,  -- signature help float while typing
    lsp_rolling_log    = true,  -- cap the ever-growing lsp.log (true, false, or { max_bytes, keep })
    -- diagnostics  = { ... }, -- passed straight to vim.diagnostic.config
    -- settings     = { lua_ls = { settings = {...} } }, -- per-server overrides
    -- capabilities = ..., on_attach = function(client, bufnr) ... end,
  },
  tsconfig = {
    highlight = true,
    fold      = true,   -- foldmethod=expr using the Treesitter foldexpr
    fold_open = true,   -- start with all folds open
    aliases   = {},     -- map a filetype to a parser, e.g. { typescriptreact = "tsx" }
    disable   = {},     -- languages to skip: a list, or a predicate(lang, bufnr)
    -- on_attach = function(bufnr, lang) ... end,
  },
  completion = {
    delay          = 100,           -- debounce before autotriggering, in ms
    key            = "<C-Space>",   -- manual trigger (insert mode)
    tab_completion = true,          -- <Tab>/<S-Tab> confirm + snippet navigation
    cr_confirm     = true,          -- <CR> confirms the current candidate
    source_order   = { "completefunc", "omnifunc" },
  },

  -- Editor behaviour
  tweaks = {
    highlight_on_yank    = true,  -- briefly highlight yanked text
    restore_cursor       = true,  -- jump to last cursor position when reopening a file
    auto_create_dir      = true,  -- create missing parent directories on save
    auto_reload          = true,  -- reload files changed outside Neovim
    quick_close          = false, -- close help/qf/man/... buffers with q
    disable_auto_comment = false, -- stop auto-continuing comment leaders
    trim_whitespace      = false, -- strip trailing whitespace on save
    auto_nohlsearch      = false, -- clear search highlighting on the triggers below
    auto_nohlsearch_triggers = {
      on_insert     = true,  -- when entering insert mode
      on_win_change = false, -- when changing window
    },
  },
  largefile = {
    size_threshold   = 1.5 * 1024 * 1024, -- bytes above which a file is treated as large
    disable_syntax   = true,              -- leave syntax highlighting off
    disable_folding  = true,
    disable_swapfile = true,
    disable_undofile = false,
    notify           = true,              -- announce when a buffer opens in fast mode
  },
  marksigns = {
    -- which marks to sign, most significant first
    marks         = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
    combine       = true,                         -- pack two names into one sign
    hl_local      = "KeystoneMarkSignsLocal",     -- highlight for a-z marks
    hl_global     = "KeystoneMarkSignsGlobal",    -- highlight for A-Z marks
    sign_priority = 5,                            -- sign priority against other plugins
  },
  scope = {
    scope             = true,  -- guide along the scope under the cursor
    guides            = true,  -- guide on every indent level
    scope_char        = "│",   -- one cell wide
    guide_char        = "│",   -- one cell wide
    exclude_filetypes = {},    -- extra filetypes left alone
  },
  animate = {
    speed    = 20,  -- ms per line
    duration = 300, -- hard cap on animation length, in ms
    step     = 16,  -- frame interval in ms
    -- filter = function(buf) ... end, -- return false to skip a buffer
    -- easing = function(i) ... end,
  },

  -- Replaces something built in
  statusline = {
    sections = {
      left  = { "mode", "filename" },
      right = { "lsp_progress", "diagnostics", "filetype", "position" },
    },
  },
  select = {
    sort            = false, -- order filtered items by fuzzy score, not the caller's order
    with_preview    = {      -- sizing when the caller offers a preview
      width_ratio  = 0.8,     -- fraction of the editor width the picker occupies
      height_ratio = 0.7,     -- fraction of the editor height the picker occupies
    },
    without_preview = {      -- sizing when it does not; the items decide, within these
      min_width_ratio  = 0.4, -- width the list keeps however narrow its labels
      max_width_ratio  = 0.8, -- width the widest label may grow the list to
      min_height_ratio = 0.2, -- height the list keeps however few the items
      max_height_ratio = 0.7, -- height the picker may grow to
    },
  },
  notify = {
    width        = 0.3,        -- fraction of the editor width
    border       = "rounded",
    timeout      = 3000,
    lsp_progress = false,      -- surface LSP progress as notifications
    lsp_progress_delay = 1000, -- skip progress for short-lived tasks
    history_limit = 100,
  },
  clue = {
    delay = 300,          -- ms before the popup appears
    border = "rounded",
    max_desc_width = 40,  -- crop long descriptions with …
    preset = true,        -- register built-in g/z/window descriptions
    builtin = { marks = true, registers = true },
    -- triggers = { ... } -- override the default trigger list
  },

  -- Adds a command, does nothing until you run it
  filetree = {
    width_ratio = 0.2,             -- fraction of the editor width (left/right)
    height_ratio = 0.2,            -- fraction of the editor height (top/bottom)
    position = "left",             -- side the window opens on
                                   -- ("top"|"bottom"|"left"|"right")
    follow_current_buffer = false, -- reveal the current file as you switch buffers
  },
  explore = {
    detail_fields = { "size", "mtime" }, -- per-entry details, in the order given
  },
  symboltree = {
    width_ratio    = 0.2,   -- fraction of the editor width
    track_cursor   = true,  -- highlight/follow the symbol under the cursor
    auto_expand    = true,  -- expand every symbol on load
    show_detail    = true,  -- show the server-provided detail text
    exclude_kinds  = nil,   -- LSP symbol kind names to hide, e.g. { "Variable" }
    collapse_kinds = { "Function", "Method", "Object" },
                            -- kinds left collapsed on load even when auto_expand is set
    debounce_ms    = 500,   -- edit-to-refresh delay
  },
  calltree = {
    width_ratio      = 0.2,        -- fraction of the editor width (left/right)
    height_ratio     = 0.2,        -- fraction of the editor height (top/bottom)
    position         = "bottom",   -- side the window opens on
                                   -- ("top"|"bottom"|"left"|"right")
    direction        = "incoming", -- which way to walk ("incoming"|"outgoing")
    show_detail      = true,       -- show the server-provided detail text
    auto_expand_root = true,       -- expand the root as soon as it resolves
  },
  diffunsaved = {},
  bufdelete = {
    ignore_floats            = true,  -- keep buffers shown in a floating window
    ignore_file_types        = {},    -- keep these filetypes
    ignore_filename_patterns = {},    -- keep names matching these Lua patterns
    ignore_alt_file          = false, -- keep the alternate file (`#`)
    ignore_special_buffers   = true,  -- keep buffers with a non-empty `buftype`
  },
})
```

These are the values the module pages use in their own examples, so treat them as
a starting point to edit rather than as the defaults — `true` is what gives you
the defaults. Each module's options are documented on its own page under
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
| [lspsetup](docs/lspsetup.md) | Enables configured LSP servers, with log rotation |
| [tsconfig](docs/tsconfig.md) | Treesitter highlighting and folding, per buffer |
| [marksigns](docs/marksigns.md) | Shows the marks that are set in the sign column |
| [scope](docs/scope.md) | Guides along the current scope and indent levels |
| [largefile](docs/largefile.md) | Opens large files without Treesitter, LSP or ftplugins |
| [notify](docs/notify.md) | A floating notification UI |
| [select](docs/select.md) | A floating `vim.ui.select` prompt with fuzzy filtering |
| [diffunsaved](docs/diffunsaved.md) | Diff modified buffers against disk |
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
- |keystone-lspsetup| Enables configured LSP servers, with log rotation
- |keystone-tsconfig| Treesitter highlighting and folding, per buffer
- |keystone-marksigns| Shows the marks that are set in the sign column
- |keystone-scope| Guides along the current scope and indent levels
- |keystone-largefile| Opens large files without Treesitter, LSP or ftplugins
- |keystone-notify| A floating notification UI
- |keystone-select| A floating `vim.ui.select` prompt with fuzzy filtering
- |keystone-diffunsaved| Diff modified buffers against disk
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
| `:DiffUnsaved` | [diffunsaved](docs/diffunsaved.md) | Diff unsaved buffers against disk |
| `:BDelete` `:BWipeout` `:BDeleteHidden` `:BWipeoutHidden` | [bufdelete](docs/bufdelete.md) | Delete or wipe buffers, keeping the window layout |

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
- `:FileTree` |keystone-filetree| Open the file-tree side window
- `:FileSelector` |keystone-explore| Open the file selector
- `:CallTree` |keystone-calltree| Show the call hierarchy of the symbol under
  the cursor
- `:SymbolTree` |keystone-symboltree| Toggle the document-symbol side window
- `:Notifications` |keystone-notify| List or clear the notification history
- `:DiffUnsaved` |keystone-diffunsaved| Diff unsaved buffers against disk
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

[MIT](LICENSE). Third-party credits: [ATTRIBUTIONS.md](ATTRIBUTIONS.md).

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
MIT. See LICENSE and ATTRIBUTIONS.md in the repository for third-party credits.
-->
