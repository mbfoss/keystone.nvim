# notify

A floating notification UI, optionally including LSP progress messages.

<!-- panvimdoc-ignore-start -->

![Notifications of each level stacking and timing out](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/notify.gif)

<!-- panvimdoc-ignore-end -->

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

## Commands

| Command | Purpose |
| --- | --- |
| `:Notifications` | List the notification history, newest first (same as `list`) |
| `:Notifications list` | List the notification history, newest first |
| `:Notifications clear` | Discard the notification history |

<!-- panvimdoc-ignore-start -->

The list goes through `vim.ui.select`: keystone's own [select](select.md)
module when it is enabled, whichever implementation is installed otherwise.

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
The list goes through `vim.ui.select`: keystone's own |keystone-select|
module when it is enabled, whichever implementation is installed otherwise.
-->
Pickers that support previews show the full message beside the list; confirming
an entry opens it in a scratch buffer.

<!-- panvimdoc-ignore-start -->

---

[← All modules](../README.md#modules)

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
All modules: |keystone-modules|
-->
