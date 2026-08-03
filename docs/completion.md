# completion

A source-agnostic autocompletion engine. It decides *when* to complete
(autotrigger or the manual key) and fires the sources in `source_order`; on
Neovim ≥ 0.11 the `omnifunc` source is the built-in `vim.lsp.completion`.

## Configuration

```lua
require("keystone").setup({
  completion = {
    delay          = 100,           -- debounce before autotriggering, in ms
    key            = "<C-Space>",   -- manual trigger (insert mode)
    tab_completion = true,          -- <Tab>/<S-Tab> confirm + snippet navigation
    cr_confirm     = true,          -- <CR> confirms the current candidate
    source_order   = { "completefunc", "omnifunc" },
  },
})
```

---

[← All modules](../README.md#modules)
