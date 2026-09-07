# completion

A source-agnostic autocompletion engine. It decides *when* to complete
(autotrigger or the manual key) and fires the sources in `source_order`; on
Neovim ≥ 0.11 the `omnifunc` source is the built-in `vim.lsp.completion`.

<!-- panvimdoc-ignore-start -->

![Autotriggered LSP candidates, narrowed by typing and confirmed with <CR>](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/completion.gif)

<!-- panvimdoc-ignore-end -->

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

<!-- panvimdoc-ignore-start -->

---

[← All modules](../README.md#modules)

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
All modules: |keystone-modules|
-->
