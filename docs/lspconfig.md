# lspconfig

Sensible LSP defaults on top of Neovim's built-in `vim.lsp` — most importantly,
it actually *enables* your configured servers, which vanilla Neovim leaves to
you.

## Configuration

```lua
require("keystone").setup({
  lspconfig = {
    servers     = "all",  -- "all" enables every config found in lsp/ dirs, or a list of names
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
