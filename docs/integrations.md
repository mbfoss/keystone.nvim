# Optional integrations

## ezpick.nvim

The fuzzy picker that used to be `keystone.pick` is now a separate plugin,
[ezpick.nvim](https://github.com/mbfoss/ezpick.nvim). Keystone does not require
it, but picks it up automatically when both are installed:

- **[notify](notify.md)** — keystone's notification history is registered as an
  ezpick source, so `:Pick notifications` browses it.
- **[bookmarks](bookmarks.md)** — the bookmark list is registered as an ezpick
  source, so `:Pick bookmarks` matches on the location *and* the label, shows
  labels on a virtual line, and previews the bookmarked file.

Without ezpick these sources are simply not registered; nothing else changes,
and nothing needs configuring either way. Keystone's own list prompts
(`:Bookmark pick`, `:DiffUnsaved`) go through `vim.ui.select` — whichever
implementation you have installed, keystone's [select](select.md) module or
anything else — and never depend on ezpick.

### Migrating from an older keystone

```lua
-- before
require("keystone").setup({ pick = true })
-- after
require("ezpick").setup()
```

The `:Pick` command, the built-in sources and `register(name, spec)` are
unchanged. The highlight groups were renamed `KeystonePick*` → `EzPick*`, and
saved picker query history moved from `stdpath("data")/keystone/` to
`stdpath("data")/ezpick/`.

---

[← README](../README.md)
