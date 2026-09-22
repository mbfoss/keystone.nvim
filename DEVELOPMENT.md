# Development

Technical notes for working on keystone.nvim.

## Requirements

- Neovim ≥ 0.11 (enforced at load time in [`plugin/keystone.lua`](plugin/keystone.lua))
- [busted](https://lunarmodules.github.io/busted/) for the test suite,
  installed for Lua 5.1 (see below)

## Testing

Tests use [busted](https://lunarmodules.github.io/busted/), live in
[`tests/`](tests/) and are discovered through [`.busted`](.busted). They run
through [`tests/nvim-lua`](tests/nvim-lua), so each spec executes inside a real
Neovim and can use the `vim` API.

```bash
# Run the whole suite
make test

# Pass flags through to busted
make test BUSTED_ARGS="--filter=symboltree -o gtest"
make test BUSTED_ARGS=tests/calltree_spec.lua
```

busted must already be installed for Lua 5.1, the version Neovim embeds:
`luarocks --lua-version=5.1 --local install busted`. `make test` fails if it is
missing rather than installing it. The runner lives in the
[`Makefile`](Makefile); [`tests/init.lua`](tests/init.lua) is the busted helper
that puts the plugin on the runtimepath.

## Architecture

Self-contained feature modules under [`lua/keystone/`](lua/keystone/). Each
(`keystone.tweaks`, `keystone.filetree`, …) exposes `setup(opts)` and can be
required directly, with no dependency on the others.

### The aggregator

[`lua/keystone/init.lua`](lua/keystone/init.lua) is an optional entry point for a
single `require("keystone").setup({...})` call. It is deliberately thin:

- `_MODULES` lists the configurable modules in setup order.
- Each key in the user table maps to a `keystone.<name>` module.
- A module is configured only when its key is present and not `false`:
  `true` → module defaults (`setup({})`), a table → `setup(table)`.
- Unknown keys produce a warning; unmentioned modules are never touched.

Adding a new module means writing `lua/keystone/<name>.lua` with a `setup(opts)`
function and adding its name to `_MODULES`.

### Shared toolkit (`util`)

[`lua/keystone/util/`](lua/keystone/util/) holds the primitives modules build on:
floating/fixed/input windows, a tree buffer, an LRU cache, throttle/debounce,
timers, a signal type, string/fs utilities, process spawning, spinners, and
user-command registration. Extend `util` rather than duplicating low-level
plumbing in a feature module.

### Lazy loading

Modules keep `setup` cheap and defer heavy work until first use. Common
patterns:

- Interactive command implementations live in a submodule that is only
  `require`d the first time the command runs (e.g. `keystone.unsaved.session`,
  `keystone.explore.explorer`).
- User commands are created with `nvim_create_user_command` directly, with the
  callbacks delegating to `keystone.util.usercmd`: `handle(opts, run_fn)` in the
  command body and `complete(arg_lead, cmd_line, subcommand)` in the `complete`
  callback. Requiring the module *inside* those callbacks keeps it out of
  `setup`. It parses no arguments itself: dispatch passes `opts.fargs` through,
  and completion runs its raw command line back through `nvim_parse_cmd`. Both
  paths therefore split by Vim's `<f-args>` rules (`:h <f-args>`).

### Choosing from a list

Modules that prompt for a choice call **`vim.ui.select`**, never a keystone
picker directly. Which implementation answers is up to the user.

[`keystone.select`](lua/keystone/select.lua) is one such implementation, a module
like any other: its `setup` assigns `vim.ui.select`, and nothing in keystone
requires it. It is the minimal subset for that interface — a prompt float, a
fuzzy-filtered list float, an optional preview float — with no sources, async
finders, query flags or history.

`opts.preview_item` is its one extension over `vim.ui.select.Opts`:

```lua
preview_item = function(item) return { buf = <bufnr>, pos = { lnum, col } } end
```

The caller hands back a **buffer**, so a modified buffer previews as it stands.
To preview a file, read it into a scratch buffer (see `keystone.unsaved.session`)
rather than loading it — loading fires the whole autocmd chain and prompts on a
stale swap file. Implementations that do not know the option ignore it, so it is
safe to pass unconditionally; annotate the opts table
`---@type keystone.select.Opts` so the language server resolves it without
requiring the module.

Callers today: `keystone.unsaved.session.open`,
[`keystone.notify.picker`](lua/keystone/notify/picker.lua) (`:Notifications`).

### Notable module internals

- **largefile**: assigns a sentinel filetype (default `bigfile`) during filetype
  detection, so no `FileType`-keyed attach handler matches — nothing has to be
  torn down after the load. A `FileType <sentinel>` autocmd applies buffer-local
  tweaks and optionally restores regex syntax.
- **lspconfig**: Neovim never rotates `lsp.log`. With `lsp_rolling_log`, keystone
  copies the live log to `.1` (shifting older `.N` up) and **truncates in
  place**. Truncation rather than rename is deliberate: Neovim caches an
  append-mode handle, so an `O_APPEND` write after truncation lands at offset 0.
- **clue**: each trigger is a `nowait` keymap; the engine reads the next keys,
  shows the continuation popup after a delay, then re-feeds the resolved
  sequence so the real mapping runs natively.
- **statusline**: sections are pluggable providers with `render` / `enable` /
  `disable` / `highlights`. Built-in sections are registered exactly like
  user-provided ones via `M.register`.
- **scope**: guides are ephemeral extmarks set from a decoration provider, so
  only the lines being redrawn are computed and nothing is stored in the buffer.
  A cursor move redraws nothing by itself, so when the scope changes both the
  rows it covered and the rows it now covers are redrawn. `blend=` applies only
  to floats and the popup menu, so the fade is baked into a colour instead: the
  foreground of `NonText` mixed into the background of `Normal`, kept in the
  `…Default` groups and rebuilt on every `ColorScheme`. Only the foreground is
  carried over, since a background would paint a block behind each one-cell
  guide. The mix is 24-bit, so without `'termguicolors'` the groups render from
  their unfaded `cterm` attributes and only `scope_char` / `guide_char` tell the
  guides apart. A window whose `'winhighlight'` background is not `Normal`'s
  fades towards the wrong colour.
- **completion**: a source-agnostic trigger engine. It decides *when* to complete
  and fires the sources in `source_order` as black boxes; the LSP item lifecycle
  belongs to the source (`vim.lsp.completion`).

## Coding style

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
tests/                     busted specs
```
