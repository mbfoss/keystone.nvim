# notes

Persistent notes that survive across sessions. A note is a piece of text; it may
also name a location, by writing `@<path>` anywhere in it. A reference that names
a line as well gets a sign in that file's sign column and follows the line as you
edit around it.

![Writing notes on a line and free-standing, then editing them in :Note list](assets/notes.gif)

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
| `list` | Edit all notes in a split |
| `clear_file` | Remove every note anchored in the current file |
| `clear_all` | Remove every note |

`add` opens an empty prompt and appends a reference to the cursor's line to
whatever you type. On a line that already carries a note it re-opens that note for
editing — seeded with its text minus the reference, since a fresh one is appended
on confirm.

## Format

Notes are stored, and shown in `:Note list`, one per line. A note is free text;
a location is an `@` reference sitting anywhere inside it:

```
remember to revisit the cache invalidation
off-by-one in @~/src/parser.lua:142 — check the bounds
@~/src/lexer.lua needs a rewrite before any of this
```

A reference is `@<path>`, optionally followed by `:<line>`. With a line it is
anchored: it gets a sign, follows the line as the file is edited, and `<CR>`
jumps straight to it. Without one it just names a file, which `<CR>` opens at the
top. Text naming no location at all is a perfectly good note — nothing is ever
rejected as malformed.

The reference has to start a token, so an address like `bob@example.com` stays
plain text. Only the first reference in a line counts; any others are text. The
reference stays part of the note rather than being split off, and is highlighted
(`KeystoneNoteRef`, linked to `Directory` by default) so it reads apart from the
prose.

`:Note list` is a scratch buffer, not the file on disk. Edit it freely: changes
flow into the notes (and their signs) as you type, and the file is written on
exit — `:w` is unnecessary. `<CR>` jumps to the note under the cursor.

Typing `@` where a reference can start — at the beginning of a line or after
whitespace — opens path completion straight away. Elsewhere `@` is just a
character, so `bob@example.com` types normally. `<C-x><C-u>` triggers the same
completion by hand.

Because the line number lives in the note's own text, an anchored note rewrites
its own `:<line>` as the file it points at is edited.

---

[← All modules](../README.md#modules)
