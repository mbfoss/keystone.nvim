# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run tests (requires nvim + plenary.nvim)
make test

# Run tests with a custom plenary path
NVIM_PLENARY_DIR=/path/to/plenary.nvim make test
```

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s busted runner. If `NVIM_PLENARY_DIR` is not set, plenary is cloned into `/tmp/plenary.nvim` automatically. Tests live in `tests/` and are discovered by `PlenaryBustedDirectory`.

Requires Neovim >= 0.10.

## Architecture

keystone.nvim is a quality-of-life Neovim plugin. Each feature is structured as a public-API module at `lua/keystone/<feature>.lua` paired with a `lua/keystone/<feature>/` directory for implementation details. The entry point `plugin/keystone.lua` only does a version check.

### Feature modules

| Module | User command | Description |
|--------|-------------|-------------|
| `pick` | `:Pick <type>` | Floating async fuzzy picker; overrides `vim.ui.select` by default |
| `filetree` | `:FileTree <cmd>` | Sidebar file tree |
| `explore` | `:FileSelector <cmd>` | Floating file explorer/selector |
| `notify` | — | Replaces `vim.notify` with floating notifications + LSP progress |
| `lspwords` | — | Document highlight (LSP word references) on cursor move |
| `animate` | — | Scroll/cursor animation |
| `focus` | — | Float preview of current buffer |
| `objects` | — | Treesitter text objects (`ia`/`aa`, `if`/`af`, `ic`/`ac`, `ib`/`ab`) |
| `colors` | — | Semantic pastel colorscheme (palette, highlight blending) |

Each feature's `setup(opts)` merges opts with defaults and registers its user command via `utils/usercmd.register_user_cmd`.

### Picker engine (`lua/keystone/pick/base/`)

`picker.lua` is the core: a floating window with a prompt, an async results list, and an optional preview pane. Callers supply a `finder` function `(query, opts, callback)` that calls `callback(items)` as results arrive. Items carry `label_chunks` (highlight-aware text segments) and `data`. Layout math lives in `layouts.lua`; fuzzy match scoring in `pickertools.lua`.

Pickers in `lua/keystone/pick/pickers/` each call `picker.open(opts, callback)` and provide a finder backed by ripgrep, LSP, git, or Neovim APIs.

### TreeBuffer (`lua/keystone/utils/TreeBuffer.lua`)

Reusable class that renders an indented, expandable tree into a Neovim buffer with virtual text. `FileTree` (`lua/keystone/filetree/FileTree.lua`) is its primary consumer — it wraps `TreeBuffer` with filesystem-aware expand/collapse logic, async directory loading, and LRU caching.

### Utilities (`lua/keystone/utils/`)

- `class.lua` — minimal prototype-based OOP; `class(base)` returns a table with `:new(...)` that calls `:init(...)`
- `Process.lua` — async subprocess wrapper around `vim.uv`
- `floatwin.lua` / `inputwin.lua` — helpers for creating floating windows and input prompts
- `Tree.lua` — generic tree data structure used by `TreeBuffer`
- `Trackers.lua` — event/callback registration
- `LRU.lua` — LRU cache
- `Spinner.lua` — animated spinner for async operations
- `throttle.lua` — throttle/debounce
- `fsutils.lua` — filesystem helpers
- `uitools.lua` — Neovim UI helpers
- `usercmd.lua` — registers user commands with subcommand completion
