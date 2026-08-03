# lspconfig

Defaults and per-server configuration on top of Neovim's built-in `vim.lsp`.
Neovim requires an explicit `vim.lsp.enable()` call for each server; this module
enables the configs it finds in `lsp/` directories on the runtimepath, and
applies the formatting, inlay hint, document highlight and signature help
settings below.

![Diagnostics, hover on an annotated function, and reference highlighting](assets/lspconfig.gif)

## Scope

Despite the name, this is **not**
[nvim-lspconfig](https://github.com/neovim/nvim-lspconfig), and it is not a
replacement for it. It runs one step later in the chain:

| Step | Provided by |
| --- | --- |
| Installing the server binary | your package manager, [mason.nvim](https://github.com/mason-org/mason.nvim), … |
| A config for the server (`cmd`, `filetypes`, `root_markers`) | nvim-lspconfig, or an `lsp/<name>.lua` you write |
| The LSP client, `vim.lsp.config` / `vim.lsp.enable` | Neovim itself |
| **Enabling those configs, and the settings around them** | **this module** |

### What it does

- **Enables servers.** Neovim will not start a server until something calls
  `vim.lsp.enable()`. With `servers = "all"` this module scans the runtimepath
  for `lsp/*.lua` and enables every config it finds; with a list, only those.
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

### What it does not do

- **It does not install language servers.** The binary has to already be on
  `PATH` — via mason, your system package manager, or however you prefer. If a
  config's `cmd` cannot run from a shell, enabling it changes nothing.
- **It does not ship server configurations.** There is no `lsp/` directory in
  this repository. It enables configs that *already exist* on your runtimepath —
  most commonly nvim-lspconfig's, which ships them as `lsp/<name>.lua` for
  exactly this mechanism, or your own in `~/.config/nvim/lsp/`.
- **It does not define keymaps.** Neovim's global defaults are what you get —
  `gra`, `gri`, `grn`, `grr`, `grt`, `grx`, `gO` and insert-mode `<C-s>` (see
  `:help lsp-defaults`).

### Using it alongside nvim-lspconfig

The two do not fight over starting servers. nvim-lspconfig does not enable
anything on its own: loading it registers `:LspInfo`, `:LspLog`, `:LspStart`,
`:LspRestart` and `:LspStop`, creates no autocmds, and never calls
`vim.lsp.enable()`. Activation is left to you — or, here, to this module.

Enabling the same server twice is also harmless: `vim.lsp.enable()` is
idempotent, so a server enabled by this module *and* by a `vim.lsp.enable()`
call of your own still produces exactly one client.

What does change is the meaning of `servers = "all"`. It enables every
`lsp/*.lua` on the runtimepath, and nvim-lspconfig ships **407** of them — one
per server it supports, not one per server you have installed. Configs whose
`cmd` is not executable are skipped, with the error going to `lsp.log` rather
than to the screen, so the practical effect is confined to the ones you do have
installed. Still, with nvim-lspconfig on the runtimepath, name the servers
explicitly:

```lua
require("keystone").setup({
  lspconfig = { servers = { "lua_ls", "pyright", "clangd" } },
})
```

`servers = "all"` is aimed at the case where the only `lsp/` directory is your
own, and every config in it is one you wrote and installed a binary for.

So a working setup is usually three things, only the last of which is keystone:

```lua
-- 1. the binary            $ brew install lua-language-server
-- 2. a config for it       nvim-lspconfig, or ~/.config/nvim/lsp/lua_ls.lua
-- 3. enable it + settings
require("keystone").setup({ lspconfig = true })
```

If you already call `vim.lsp.enable()` yourself and want nothing else from this
module, you do not need it.

## Configuration

```lua
require("keystone").setup({
  lspconfig = {
    servers     = "all",  -- every config found in lsp/ dirs, or a list of names.
                          -- See the note above before using "all" with nvim-lspconfig.
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

---

[← All modules](../README.md#modules)
