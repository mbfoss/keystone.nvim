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
`keystone.filetree`, …) exposes a `setup(opts)` function and can be required and
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

### Shared toolkit (`util`)

[`lua/keystone/util/`](lua/keystone/util/) holds the reusable primitives that
modules build on — floating/fixed/input windows, extmark helpers, a tree
buffer, an LRU cache, throttle/debounce, timers, a signal type, string/fs
utilities, process spawning, spinners, and user-command registration. Prefer
extending `util` over duplicating low-level plumbing inside a feature module.

### Lazy loading

Modules keep `setup` cheap and defer heavy work until first use. Common
patterns:

- Interactive command implementations live in a submodule that is only
  `require`d the first time the command runs (e.g. `keystone.notes.actions`,
  `keystone.unsaved.session`).
- User commands are created with `nvim_create_user_command` directly, with the
  callbacks delegating to `keystone.util.usercmd`: `handle(opts, run_fn)` in the
  command body and `complete(arg_lead, cmd_line, subcommand)` in the `complete`
  callback. Requiring the module *inside* those callbacks keeps it — and
  whatever the subcommand closure pulls in — out of `setup`. It parses no
  arguments itself: dispatch passes
  Neovim's `opts.fargs` straight through, and completion — which is handed a
  raw command line rather than parsed arguments — runs that line back through
  `nvim_parse_cmd`. Both paths therefore split by Vim's `<f-args>` rules
  (`:h <f-args>`): unescaped whitespace separates, `\<space>` is a literal
  space, `\\` is a backslash, and quotes are not special.

### Choosing from a list

Modules that prompt for a choice call **`vim.ui.select`** — never a keystone
picker directly. Which implementation answers is up to the user.

[`keystone.select`](lua/keystone/select.lua) is one such implementation, and a
module like any other: its `setup` assigns `vim.ui.select`, and nothing in
keystone requires it. It is deliberately the *minimal* subset needed for that
interface — a prompt float, a fuzzy-filtered list float, an optional preview
float; no sources, no async finders, no query flags, no history. Anything richer
belongs in a picker plugin.

`opts.preview_item` is its one extension over `vim.ui.select.Opts`:

```lua
preview_item = function(item) return { buf = <bufnr>, pos = { lnum, col } } end
```

The caller hands back a **buffer** and the picker displays it, so a live,
modified buffer previews as it currently stands. Callers that want to preview a
file rather than a buffer read it into a scratch buffer themselves (see
`keystone.notes.actions`) instead of loading it — loading fires the whole
autocmd chain and prompts on a stale swap file. Implementations that do not know
the option ignore it, so it is safe to pass unconditionally; annotate the opts
table `---@type keystone.select.Opts` so the language server resolves it without
requiring the module.

Callers today: `keystone.unsaved.session.open`,
[`keystone.notify.picker`](lua/keystone/notify/picker.lua) (`:Notifications`).

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
plugin/keystone.lua        Neovim version guard (loaded on startup)
lua/keystone/init.lua      optional single-entry aggregator
lua/keystone/select.lua    a `vim.ui.select` implementation (a module like any other)
lua/keystone/<module>.lua  one file per feature module
lua/keystone/<module>/     a module's private submodules
lua/keystone/util/         shared low-level toolkit
tests/                     plenary busted specs
```
