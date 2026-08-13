# Optional integrations

## ezpick.nvim

[ezpick.nvim](https://github.com/mbfoss/ezpick.nvim) is a separate fuzzy picker
plugin. Keystone does not require it, and detects it when both are installed:

- **[notify](notify.md)** — the notification history is registered as an ezpick
  source, so `:Pick notifications` browses it.
Without ezpick that source is not registered; nothing else differs, and it needs
no configuring either way. Keystone's own list prompts (`:DiffUnsaved`) go
through `vim.ui.select` — whichever implementation is installed, keystone's
[select](select.md) module or another — and do not depend on ezpick.

---

[← README](../README.md)
