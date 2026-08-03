# bookmarks

Persistent, optionally labelled line bookmarks that survive across sessions.

## Configuration

```lua
require("keystone").setup({
  bookmarks = {
    persist_path = nil,               -- bookmarks file; nil = ~/.nvimbookmarks
    sign_text    = "*",
    sign_hl      = "DiagnosticInfo",
  },
})
```

## Commands

`:Bookmark <sub>`, where `<sub>` is one of:

| Subcommand | What it does |
| --- | --- |
| `set` | Bookmark the current line |
| `setlabel` | Bookmark the current line with a label |
| `delete` | Remove the bookmark on the current line |
| `pick` | Choose a bookmark to jump to |
| `list` | List all bookmarks |
| `clear_file` | Remove every bookmark in the current file |
| `clear_all` | Remove every bookmark |

## Integrations

With [ezpick.nvim](integrations.md#ezpicknvim) installed, the bookmark list is
registered as a picker source — see [integrations](integrations.md).

---

[← All modules](../README.md#modules)
