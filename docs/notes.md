# notes

Persistent notes that survive across sessions. A note is a piece of text; it may
also name a location, by writing `@<path>` anywhere in it.

![Writing notes on a line and free-standing, then editing them in :Notes list](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/notes.gif)

## Configuration

```lua
require("keystone").setup({
  notes = {
    persist_path = nil,   -- notes file; nil = ~/.nvimnotes
  },
})
```

## Commands

`:Notes <sub>`, where `<sub>` is one of:

| Subcommand | What it does |
| --- | --- |
| `list` | Open the notes file in a split (the default, so bare `:Notes` does this) |
| `add` | Write a note anchored to the current line (prompts for the text) |
| `add_free` | Write a note with no location |

`add` opens an empty prompt and appends a reference to the cursor's line to
whatever you type. Both commands only ever append a line — nothing is rewritten,
and a line that already carries a note simply gets a second one. Removing a note
is deleting its line in `:Notes list`.

## Format

The notes file is an ordinary text file, one note per line. A note is free text;
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
location at all is still a note — nothing is rejected as malformed.

A note may carry any number of references. The **first** one is the note's own
location; the rest are ordinary references, and `<CR>` follows whichever one the
cursor is on.

The reference has to start a token, so an address like `bob@example.com` stays
plain text. Lines are stored exactly as written — nothing parses or rewrites them
on the way to disk — and references are highlighted (`KeystoneNoteRef`, linked to
`Directory` by default) so they read apart from the prose.

`:Notes list` opens the notes file itself in a split: an ordinary buffer, edited
like any other. Delete a note by deleting its line. Edits are written on exit, so
`:w` is optional — though a buffer left modified makes `:qa` fail with E37
(`:wqa` writes everything, `:qa!` still triggers the exit write). The write skips
`BufWritePre`, so a formatter registered on that event does not run over the
notes file.

`<CR>` opens the reference under the cursor — at its line, or at the
top of the file when the reference names no line. With the cursor on prose rather
than a reference, `<CR>` does nothing.

Adding a note while that buffer is open appends the line to the buffer rather
than to the file, so the two do not diverge, and writes the buffer out.

Typing `@` where a reference can start — at the beginning of a line or after
whitespace — opens path completion straight away. Elsewhere `@` is just a
character, so `bob@example.com` types normally. `<C-x><C-u>` triggers the same
completion by hand.

---

[← All modules](../README.md#modules)
