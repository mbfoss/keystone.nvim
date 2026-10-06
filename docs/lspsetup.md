# lspsetup

Defaults and per-server configuration on top of Neovim's built-in `vim.lsp`.
Neovim requires an explicit `vim.lsp.enable()` call for each server; this module
makes that call for the servers you name in `servers`, chosen from the configs
it finds in `lsp/` directories on the runtimepath, and applies the formatting,
inlay hint, document highlight and signature help settings below.

<!-- panvimdoc-ignore-start -->

![Diagnostics, hover on an annotated function, and reference highlighting](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/lspconfig.gif)

<!-- panvimdoc-ignore-end -->

## Scope <!-- tag: scope -->

This is **not**
[nvim-lspconfig](https://github.com/neovim/nvim-lspconfig), nor a replacement for
it. It runs one step later in the chain:

| Step | Provided by |
| --- | --- |
| Installing the server binary | your package manager, [mason.nvim](https://github.com/mason-org/mason.nvim), … |
| A config for the server (`cmd`, `filetypes`, `root_markers`) | nvim-lspconfig, or an `lsp/<name>.lua` you write |
| The LSP client, `vim.lsp.config` / `vim.lsp.enable` | Neovim itself |
| **Enabling those configs, and the settings around them** | **this module** |

### What it does <!-- tag: does -->

- **Enables servers.** Neovim will not start a server until something calls
  `vim.lsp.enable()`. Name the servers you want in `servers`; this module calls
  it for each of them on setup, so the call is not repeated per config.
- **Applies cross-cutting settings** that would otherwise be per-server
  boilerplate: `capabilities` merged into every server, `on_attach`, and
  `vim.diagnostic.config`.
- **Turns on client features** for servers that support them: inlay hints,
  document highlight of the symbol under the cursor, a signature help float, and
  format-on-save.
- **Overrides individual servers** through `settings`, merged into
  `vim.lsp.config(name, …)`.
- **Caps `lsp.log`.** Neovim never rotates it and only warns past 1 GB; this
  rotates it at `max_bytes` and keeps a limited number of rotated files.

### What it does not do <!-- tag: does-not -->

- **It does not install language servers.** The binary must already be on
  `PATH`. If a config's `cmd` cannot run from a shell, enabling it changes
  nothing.
- **It does not ship server configurations.** There is no `lsp/` directory here.
  It enables configs already on your runtimepath: nvim-lspconfig's
  `lsp/<name>.lua` files, or your own in `~/.config/nvim/lsp/`.
- **It does not define keymaps.** Neovim's global defaults are what you get,
  `gra`, `gri`, `grn`, `grr`, `grt`, `grx`, `gO` and insert-mode `<C-s>` (see
  `:help lsp-defaults`).

### Using it alongside nvim-lspconfig <!-- tag: alongside -->

The two do not fight over starting servers. nvim-lspconfig enables nothing on its
own: loading it registers `:LspInfo`, `:LspLog`, `:LspStart`, `:LspRestart` and
`:LspStop`, and never calls `vim.lsp.enable()`. Activation is left to you, or to
this module. Enabling the same server twice is harmless, since `vim.lsp.enable()`
is
idempotent.

Because `servers` names each server, nvim-lspconfig's `lsp/*.lua` configs cost
nothing here: only the ones you list are enabled. A working setup is usually
three things, only the last of which is keystone:

```lua
-- 1. the binary            $ brew install lua-language-server
-- 2. a config for it       nvim-lspconfig, or ~/.config/nvim/lsp/lua_ls.lua
-- 3. enable it + settings
require("keystone").setup({ lspsetup = { servers = { "lua_ls" } } })
```

`require("keystone.lspsetup").info()` lists the configs found on your
runtimepath, which is the list to pick those names from. If you already call
`vim.lsp.enable()` and want nothing else here, you do not need this module.

## Configuration <!-- tag: configuration -->

```lua
require("keystone").setup({
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
})
```

<!-- panvimdoc-ignore-start -->

---

[← All modules](../README.md#modules)

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
All modules: |keystone-modules|
-->
