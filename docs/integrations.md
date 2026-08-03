# Optional integrations

## ezpick.nvim

[ezpick.nvim](https://github.com/mbfoss/ezpick.nvim) is a separate fuzzy picker
plugin. Keystone does not require it, and detects it when both are installed:

- **[notify](notify.md)** — the notification history is registered as an ezpick
  source, so `:Pick notifications` browses it.
- **[bookmarks](bookmarks.md)** — the bookmark list is registered as an ezpick
  source, so `:Pick bookmarks` matches on the location *and* the label, shows
  labels on a virtual line, and previews the bookmarked file.

Without ezpick these two sources are not registered; nothing else differs, and
neither case needs configuring. Keystone's own list prompts (`:Bookmark pick`,
`:DiffUnsaved`) go through `vim.ui.select` — whichever implementation is
installed, keystone's [select](select.md) module or another — and do not depend
on ezpick.

---

[← README](../README.md)
