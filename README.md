# keystone.nvim

A quality-of-life Neovim plugin. Requires Neovim >= 0.10.

## Features

- **Pick** — floating async fuzzy picker with file, grep, LSP, git, and more
- **FileTree** — sidebar file tree with inline file management
- **FileSelector** — floating file explorer with preview and file management
- **Notify** — floating notifications with LSP progress and history
- **Statusline** — mode, git branch, filename, diagnostics, filetype, position
- **Breadcrumbs** — LSP symbol breadcrumb trail in the winbar, shown only when LSP is active
- **Animate** — smooth scroll animation
- **Treesitter** — auto-start treesitter highlighting and folds for any language with an installed parser
- **LSP Words** — auto-highlight word under cursor via LSP
- **Focus** — fullscreen floating overlay for the current buffer
- **Text Objects** — treesitter and bracket-based text objects (`ia`, `if`, `ic`, `ib`, …)
- **Clue** — which-key-style popup hinting the keys that follow a prefix
- **Colors** — semantic pastel colorscheme
- **Tweaks** — essential editor behaviors (highlight on yank, restore cursor, auto-mkdir, …)

---

## Setup

Each feature is opt-in. Call `setup()` for the ones you want:

```lua
require("keystone.colors").setup()
require("keystone.pick").setup()
require("keystone.filetree").setup()
require("keystone.notify").setup()
require("keystone.statusline").setup()
require("keystone.breadcrumbs").setup()
require("keystone.animate").setup()
require("keystone.lspwords").setup()
require("keystone.tsconfig").setup()
require("keystone.focus").setup()
require("keystone.objects").setup()
require("keystone.clue").setup()
require("keystone.tweaks").setup()
```

---

## Pick

Floating async fuzzy picker. Optionally overrides `vim.ui.select`.

```lua
require("keystone.pick").setup({
  override_ui_select = true, -- default: true
})
```

**Command:** `:Pick <type>`

| Type | Description |
|------|-------------|
| `files` | Find files in cwd |
| `live_grep` | Live ripgrep search |
| `recent_files` | Recently opened files |
| `config_files` | Files in Neovim config dir |
| `repeat_last` | Re-open last picker |
| `buffers` | Open buffers |
| `all_buffers` | All buffers including unlisted |
| `windows` | Open windows |
| `quickfix` | Quickfix list |
| `jumplist` | Jump list |
| `lsp_references` | LSP references |
| `document_symbols` | LSP document symbols |
| `document_diagnostics` | Diagnostics for current buffer |
| `workspace_diagnostics` | Workspace-wide diagnostics |
| `git_diff` | Git changed files |
| `git_hunks` | Git hunks |
| `spell_suggest` | Spell suggestions |
| `highlights` | Highlight groups |
| `autocommands` | Autocommands |
| `keymaps` | Keymaps |
| `commands` | User commands |
| `notifications` | Notification history |

---

## FileTree

Sidebar file tree with filesystem operations.

```lua
require("keystone.filetree").setup({
  width_ratio = 0.2, -- default: 20% of window width
})
```

**Command:** `:FileTree [open|close|toggle]` (defaults to `toggle`)

**Keymaps (in tree buffer):**

| Key | Action |
|-----|--------|
| `<CR>` | Open file / toggle directory |
| `a` | Create file (sibling) |
| `A` | Create directory (sibling) |
| `i` | Create file (inside directory) |
| `I` | Create directory (inside directory) |
| `r` | Rename |
| `d` | Delete (file or empty directory) |
| `R` | Refresh tree |
| `g?` | Show help |

---

## FileSelector

Floating file explorer with preview and file management.

```lua
require("keystone.explore").setup()
```

**Command:** `:FileSelector`

Opens in the directory of the current buffer (or cwd). Supports symlink resolution and file preview.

**Keymaps:**

| Key | Action |
|-----|--------|
| `<CR>` | Open file / enter directory |
| `l` | Enter directory |
| `h` | Go up to parent |
| `<Esc>` | Close |
| `a` | Create file |
| `A` | Create directory |
| `r` | Rename |
| `d` | Delete |
| `D` | Delete recursively |

---

## Notify

Floating notifications with LSP progress tracking.

```lua
require("keystone.notify").setup({
  enabled          = true,
  width            = 50,
  border           = "rounded",
  timeout          = 3000,      -- ms; 0 = no auto-close
  lsp_progress     = true,
  lsp_progress_delay = 1000,   -- ms before LSP progress appears
  history_limit    = 100,
})
```

Replaces `vim.notify`. Notifications stack at the bottom-right of the screen.

**API:**
```lua
local notify = require("keystone.notify")
notify.notify("message", { title = "Title", level = "info", timeout = 5000 })
notify.close(id)
notify.enable() / notify.disable()
notify.history()      -- returns list of past notifications
notify.clear_history()
```

---

## Statusline

```lua
require("keystone.statusline").setup({
  enabled = true,
})
```

Sections (left → right): mode indicator · git branch · filename with icon · `[modified]` / `[readonly]` · — · LSP diagnostics · filetype · line:col

Requires [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) for the branch segment.

---

## Animate

Smooth scroll animation with configurable easing.

```lua
require("keystone.animate").setup({
  enabled = true,
  -- optional: filter out specific buffers
  filter  = function(buf) return true end,
  -- optional: custom easing function (t: 0..1 → 0..1)
  easing  = require("keystone.animate").easings.in_out,
})
```

**Built-in easings:** `linear`, `out_quad`, `in_out` (default)

Animation is automatically skipped for terminal buffers, paste mode, macro recording/playback, and mouse wheel scrolling.

---

## LSP Words

Highlights all occurrences of the word under the cursor using `textDocument/documentHighlight`.

```lua
require("keystone.lspwords").setup({
  enabled = true,
})
```

**API:** `require("keystone.lspwords").enable()` / `.disable()` / `.clear()`

---

## Treesitter

Vanilla Neovim only swaps regex syntax for treesitter highlighting on the
handful of languages it bundles parsers for (c, lua, markdown, vim, …). For
every other language, even with a parser installed, you stay on regex unless
something calls `vim.treesitter.start()`. This module is that something: on
`FileType` it starts treesitter highlighting and folds for any buffer whose
language has an installed parser. It does **not** install parsers — pair it
with `nvim-treesitter` (or bundled/`packadd`'d parsers) for that.

```lua
require("keystone.tsconfig").setup({
  enabled   = true,
  highlight = true,                 -- start treesitter highlighting (replaces regex)
  fold      = true,                 -- foldmethod=expr + treesitter foldexpr
  fold_open = true,                 -- start with folds open (foldlevel=99)
  aliases   = {                     -- filetype -> parser language
    -- typescriptreact = "tsx",
  },
  disable   = {},                   -- list of langs, or fun(lang, bufnr) -> boolean
  on_attach = nil,                  -- fun(bufnr, lang), run after start
})
```

**Health:** `:checkhealth keystone.tsconfig` — reports installed parsers, which are missing highlights queries (the usual "parser but no colors" trap), and the current buffer's highlight status.

**API:** `require("keystone.tsconfig").attach(bufnr)` / `.stop(bufnr)` / `.enable()` / `.disable()` / `.is_enabled()`

---

## Focus

Fullscreen floating overlay for the current buffer.

```lua
require("keystone.focus").setup({
  enabled = true,
})
```

**Command:** `:Focus` — toggles focus mode on/off.

---

## Text Objects

Treesitter and bracket-based text objects. Registered in operator-pending and visual modes.

```lua
require("keystone.objects").setup({
  enabled = true,
})
```

| Keymap | Description |
|--------|-------------|
| `ia` / `aa` | Inner / around argument (bracket-based, comma-aware) |
| `if` / `af` | Inner / around function (treesitter) |
| `ic` / `ac` | Inner / around class (treesitter) |
| `ib` / `ab` | Inner / around block (treesitter) |

---

## Clue

A which-key / mini.clue-style popup. When a configured **trigger** key is pressed,
a floating window lists the keys that may follow it and their descriptions;
pressing more keys narrows the list.

It works as a **passive observer** via `vim.on_key` — it never consumes or replays
keys, so Neovim resolves and executes everything itself. Counts, registers,
operators and your existing mappings all behave exactly as without the plugin.

```lua
require("keystone.clue").setup({
  enabled       = true,
  builtin_clues = true,   -- hint built-in <C-w>/z/g sequences too
  triggers = {            -- triggers must each be a single key
    { mode = "n", keys = "<leader>" },
    { mode = "n", keys = "<localleader>" },
    { mode = "n", keys = "g" },
    { mode = "n", keys = "z" },
    { mode = "n", keys = "[" },
    { mode = "n", keys = "]" },
    { mode = "n", keys = "<C-w>" },
    { mode = "x", keys = "<leader>" },
    { mode = "x", keys = "<localleader>" },
    { mode = "x", keys = "g" },
    { mode = "x", keys = "z" },
  },
  groups = {              -- friendly labels for prefixes that lead to more keys
    -- ["<leader>f"] = "find",
  },
  clues = {               -- extra hints for un-mapped (built-in) sequences
    -- { mode = "n", keys = "<leader>x", desc = "diagnostics" },
  },
  win = {
    border           = "rounded",
    separator        = "  ",
    width_ratio      = 0.9,
    max_height_ratio = 0.4,
    title            = true,
  },
})
```

**Command:** `:Clue [enable|disable|toggle]` (defaults to `toggle`)

The popup appears as soon as a trigger is pressed and stays up until you act — it
is dismissed when the sequence resolves to a mapping, no longer matches, the mode
changes, or you press `<Esc>`. While a clue is pending, `'timeout'` is held off so
Neovim waits for your next key instead of resolving the prefix on its own (it is
restored as soon as the popup closes).

**Highlight groups** (linked by default, override freely): `KeystoneClueKey`,
`KeystoneClueDesc`, `KeystoneClueGroup`, `KeystoneClueSeparator`, `KeystoneClueTitle`.

---

## Colors

Semantic pastel colorscheme.

```lua
require("keystone.colors").setup({
  palette      = {},     -- optional color overrides
  notify       = true,   -- highlight keystone.notify windows
  lsp_semantic = true,   -- LSP semantic token highlights
  diffview     = true,   -- diffview.nvim highlights
  which_key    = true,   -- which-key.nvim highlights
})
```

**Palette groups:** 15 neutrals (`bg_dark` → `bright`), 9 pastel core colors, 6 vivid extensions, 6 tinted backgrounds.

---

## Tweaks

Essential editor behaviors you'd otherwise hand-roll in your config. Each is an
independent toggle, so enable only the ones you want.

```lua
require("keystone.tweaks").setup({
  enabled              = true,        -- master switch
  highlight_on_yank    = true,        -- flash the yanked region
  yank_hlgroup         = "IncSearch", -- highlight group for the flash
  yank_timeout         = 200,         -- flash duration in ms
  restore_cursor       = true,        -- reopen a file at its last cursor position
  auto_create_dir      = true,        -- mkdir -p missing parents on :write
  auto_reload          = true,        -- reload files changed outside Neovim
  equalize_splits      = true,        -- re-balance splits on resize
  quick_close          = false,       -- press q to close help/qf/man/... buffers
  quick_close_filetypes = {           -- buffers quick_close applies to
    "help", "qf", "man", "lspinfo", "checkhealth",
    "startuptime", "query", "notify", "git",
  },
  disable_auto_comment = false,       -- no comment leader on the next line
  trim_whitespace      = false,       -- strip trailing whitespace on save
})
```

| Tweak | What it does |
|-------|--------------|
| `highlight_on_yank` | Briefly highlights the text you just yanked. |
| `restore_cursor` | Jumps to the last cursor position when reopening a file (skips commit/rebase buffers). |
| `auto_create_dir` | Creates missing parent directories when you save a new file. |
| `auto_reload` | Reloads buffers changed on disk (`autoread` + `checktime` on focus/enter) and notifies you. |
| `equalize_splits` | Re-balances split sizes on `VimResized`. |
| `quick_close` | Maps `q` to close utility buffers (help, quickfix, man, …). |
| `disable_auto_comment` | Stops Neovim continuing comment leaders onto new lines. |
| `trim_whitespace` | Strips trailing whitespace on save (rewrites buffer contents). |

Individual tweaks can be toggled at runtime from Lua:

```lua
require("keystone.tweaks").toggle_feature("highlight_on_yank")
require("keystone.tweaks").disable_feature("auto_reload")
```

---

## License

See [LICENSE](LICENSE). Icon attributions in [ATTRIBUTIONS.md](ATTRIBUTIONS.md).

