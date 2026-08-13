# notes

Persistent notes that survive across sessions. A note is a piece of text; it may
also be anchored to a line, in which case it gets a sign in that file's sign
column and follows the line as you edit around it.

![Writing a note, then finding it again with :Note pick](assets/notes.gif)

## Configuration

```lua
require("keystone").setup({
  notes = {
    persist_path = nil,               -- notes file; nil = ~/.nvimnotes
    sign_text    = "*",
    sign_hl      = "DiagnosticInfo",
  },
})
```

## Commands

`:Note <sub>`, where `<sub>` is one of:

| Subcommand | What it does |
| --- | --- |
| `add` | Write a note anchored to the current line (prompts for the text) |
| `add_free` | Write a note with no location |
| `delete` | Remove the note anchored to the current line |
| `pick` | Choose a note to jump to |
| `list` | Edit all notes in a split |
| `clear_file` | Remove every note anchored in the current file |
| `clear_all` | Remove every note |

`add` on a line that already carries a note re-opens that note for editing
rather than adding a second one. On an empty prompt it starts from the text of
the line being anchored to.

## Format

Notes are stored, and shown in `:Note list`, one per line:

```
remember to revisit the cache invalidation
off-by-one in the bounds check -- src/parser.lua:142
```

The note text comes first and is the only required part. The optional location
is whatever follows the **last** whitespace-surrounded ` -- `, and only when it
parses as `<path>:<line>` — so a note that happens to contain ` -- ` keeps it,
and a line that does not name a real location is simply an unanchored note
rather than an error.

`:Note list` is a scratch buffer, not the file on disk. Edit it freely: changes
flow into the notes (and their signs) as you type, and the file is written on
exit — `:w` is unnecessary. `<CR>` jumps to the location of the note under the
cursor, and `<C-x><C-u>` completes a file path in the location field.

## Integrations

With [ezpick.nvim](integrations.md#ezpicknvim) installed, the note list is
registered as a picker source — see [integrations](integrations.md).

---

[← All modules](../README.md#modules)
