# notify

A floating notification UI, optionally including LSP progress messages.

## Configuration

```lua
require("keystone").setup({
  notify = {
    width        = 0.3,        -- fraction of the editor width
    border       = "rounded",
    timeout      = 3000,
    lsp_progress = false,      -- surface LSP progress as notifications
    lsp_progress_delay = 1000, -- skip progress for short-lived tasks
    history_limit = 100,
  },
})
```

## Integrations

With [ezpick.nvim](integrations.md#ezpicknvim) installed, the notification
history is registered as a picker source — see [integrations](integrations.md).

---

[← All modules](../README.md#modules)
