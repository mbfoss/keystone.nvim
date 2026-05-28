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
- **LSP Words** — auto-highlight word under cursor via LSP
- **Focus** — fullscreen floating overlay for the current buffer
- **Text Objects** — treesitter and bracket-based text objects (`ia`, `if`, `ic`, `ib`, …)
- **Colors** — semantic pastel colorscheme

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
require("keystone.focus").setup()
require("keystone.objects").setup()
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
| `<C-t>` | Toggle preview |
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

## Breadcrumbs

```lua
require("keystone.breadcrumbs").setup({
  enabled = true,
})
```

Displays a live LSP symbol breadcrumb trail in the winbar: `› SymbolKind Name › …`. The winbar is only set when an LSP client supporting `textDocument/documentSymbol` attaches to the buffer, and removed when the last such client detaches. An existing winbar from another plugin is never overridden.

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

## License

See [LICENSE](LICENSE). Icon attributions in [ATTRIBUTIONS.md](ATTRIBUTIONS.md).
