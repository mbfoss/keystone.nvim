# Development

Technical notes for working on keystone.nvim.

## Requirements

- Neovim ≥ 0.11 (enforced at load time in [`plugin/keystone.lua`](plugin/keystone.lua))
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) for the test suite

## Testing

Tests use plenary.nvim's busted runner and live in [`tests/`](tests/), where
they are discovered by `PlenaryBustedDirectory`.

```bash
# Run the whole suite
make test

# Run against a custom plenary checkout
NVIM_PLENARY_DIR=/path/to/plenary.nvim make test
```

If `NVIM_PLENARY_DIR` is not set, plenary is cloned into `/tmp/plenary.nvim`
automatically. The runner is defined in the [`Makefile`](Makefile) and boots
Neovim headless with [`tests/init.lua`](tests/init.lua).

## Architecture

Keystone is a collection of **self-contained feature modules** under
[`lua/keystone/`](lua/keystone/). Each module (`keystone.tweaks`,
`keystone.pick`, …) exposes a `setup(opts)` function and can be required and
configured directly, with no dependency on the others.

### The aggregator

[`lua/keystone/init.lua`](lua/keystone/init.lua) is an optional convenience
entry point for people who prefer a single `require("keystone").setup({...})`
call. It is deliberately thin:

- `_MODULES` lists the configurable modules in setup order.
- Each key in the user table maps to a `keystone.<name>` module.
- A module is configured only when its key is present and not `false`:
  `true` → module defaults (`setup({})`), a table → `setup(table)`.
- Unknown keys produce a warning; unmentioned modules are never touched.

Adding a new module means writing `lua/keystone/<name>.lua` with a `setup(opts)`
function and adding its name to `_MODULES`.

### Shared toolkit (`tk`)

[`lua/keystone/tk/`](lua/keystone/tk/) ("toolkit") holds the reusable
primitives that modules build on — floating/fixed/input windows, extmark
helpers, a tree buffer, an LRU cache, throttle/debounce, timers, a signal
type, string/fs utilities, process spawning, spinners, and user-command
registration. Prefer extending `tk` over duplicating low-level plumbing inside
a feature module.

### Lazy loading

Modules keep `setup` cheap and defer heavy work until first use. Common
patterns:

- Interactive command implementations live in a submodule that is only
  `require`d the first time the command runs (e.g. `keystone.bookmarks.actions`,
  `keystone.unsaved.session`).
- User commands are registered through `keystone.tk.usercmd`, which supports
  subcommand completion.

### Notable module internals

- **largefile** — Rather than tearing down Treesitter/LSP/ftplugins after a big
  file loads, it assigns the buffer a sentinel filetype (default `bigfile`)
  during filetype detection, so none of the `FileType`-keyed attach handlers
  ever match. A `FileType <sentinel>` autocmd then applies buffer-local tweaks
  and optionally restores cheap regex syntax.
- **lspconfig** — Neovim never rotates `lsp.log`. When `lsp_rolling_log` is
  enabled, keystone caps the file itself by copying the live log to `.1`
  (shifting older `.N` files up) and then **truncating in place**. Truncation
  rather than rename is deliberate: Neovim caches an append-mode handle to the
  live file, so an `O_APPEND` write after truncation lands at offset 0 and gives
  a clean new file.
- **clue** — Each trigger is a `nowait` keymap; the engine reads the next keys,
  shows the continuation popup after a delay, then re-feeds the resolved
  sequence so the real mapping runs natively.
- **statusline** — Sections are pluggable providers with `render` / `enable` /
  `disable` / `highlights`. Built-in sections are registered exactly like
  user-provided ones via `M.register`.
- **completion** — A source-agnostic trigger engine. It decides *when* to
  complete and fires the sources in `source_order`, treating each as a black
  box; the LSP item lifecycle belongs to the source (`vim.lsp.completion`), not
  to keystone.

## Coding style

These conventions are enforced across the codebase (see also
[`CLAUDE.md`](CLAUDE.md)):

- Add Lua annotations (`---@param`, `---@return`, `---@class`, …) wherever
  possible.
- **Class-based modules** are named in PascalCase; **functional modules** are
  named in snake_case.
- Module-scope `local` variables are prefixed with `_`, except: a module name
  from `require()`, the conventional `M` module table, and class types
  (`MyType`).
- Function-local variables are **not** prefixed with `_`.
- Inside a class, private members are prefixed with `_`.
- Avoid `pcall()` when it isn't required.

## Layout

```
plugin/keystone.lua       Neovim version guard (loaded on startup)
lua/keystone/init.lua     optional single-entry aggregator
lua/keystone/<module>.lua  one file per feature module
lua/keystone/<module>/    a module's private submodules
lua/keystone/tk/          shared low-level toolkit
tests/                    plenary busted specs
```
