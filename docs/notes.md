# notes

Persistent notes that survive across sessions. A note is a piece of text; it may
also name a location, by writing `@<path>` anywhere in it.

![Writing notes on a line and free-standing, then editing them in :Note list](assets/notes.gif)

## Configuration

```lua
require("keystone").setup({
  notes = {
    persist_path = nil,   -- notes file; nil = ~/.nvimnotes
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
compare @~/src/old.lua:20 against @~/src/new.lua:31
```

A reference is `@<path>`, optionally followed by `:<line>`. The line is part of
the note's text and nothing rewrites it, so it goes stale as the file is edited,
exactly as a line number written in any other document would. Text naming no
location at all is a perfectly good note — nothing is ever rejected as malformed.

A note may carry as many references as it likes. The **first** one is the note's
own location, the one `:Note delete` and `:Note clear_file` match against, but
every reference is real and `<CR>` follows whichever one the cursor is on.

The reference has to start a token, so an address like `bob@example.com` stays
plain text. References stay part of the note rather than being split off, and are
highlighted (`KeystoneNoteRef`, linked to `Directory` by default) so they read
apart from the prose.

`:Note list` is a scratch buffer, not the file on disk. Edit it freely: changes
flow into the notes as you type, and the file is written on exit — `:w` is
unnecessary. `<CR>` opens the reference under the cursor — at its line, or at the
top of the file when the reference names no line. With the cursor on prose rather
than a reference, `<CR>` does nothing.

Typing `@` where a reference can start — at the beginning of a line or after
whitespace — opens path completion straight away. Elsewhere `@` is just a
character, so `bob@example.com` types normally. `<C-x><C-u>` triggers the same
completion by hand.

---

[← All modules](../README.md#modules)
