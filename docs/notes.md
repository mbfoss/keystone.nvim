# notes

Persistent notes that survive across sessions. A note is a piece of text; it may
also name a location, by writing `@<path>` anywhere in it.

![Writing notes on a line and free-standing, then editing them in :Notes list](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/notes.gif)

## Configuration

```lua
require("keystone").setup({
  notes = {
    enabled      = true,  -- set false to skip the module entirely
    persist_path = nil,   -- notes file; nil = ~/.nvimnotes
  },
})
```

`persist_path` may also be a function returning the path, which is called on
every access — enough to key the notes file to whatever the current project or
branch is.

## Commands

`:Notes <sub>`, where `<sub>` is one of:

| Subcommand | What it does |
| --- | --- |
| `list` | Open the notes list in a split (the default, so bare `:Notes` does this) |
| `add` | Write a note anchored to the current line (prompts for the text) |
| `add_free` | Write a note with no location |

`add` opens an empty prompt and prefixes a reference to the cursor's line to
whatever you type, so the list reads as locations first with the note text
following. Both commands only ever append a line — nothing is rewritten, and a
line that already carries a note simply gets a second one. Removing a note is
deleting its line in `:Notes list`.

## Format

The notes file is an ordinary text file, one note per non-blank line. A note is
free text; a location is an `@` reference sitting anywhere inside it:

```
remember to revisit the cache invalidation
off-by-one in @~/src/parser.lua:142 — check the bounds
@~/src/lexer.lua needs a rewrite before any of this
compare @~/src/old.lua:20 against @~/src/new.lua:31
```

A reference is `@<path>`, optionally followed by `:<line>`. The line is part of
the note's text and nothing rewrites it, so it goes stale as the file is edited,
exactly as a line number written in any other document would. Text naming no
location at all is still a note — nothing is rejected as malformed. Only a blank
line is not a note.

A note may carry any number of references. The **first** one is the note's own
location; the rest are ordinary references, and `<CR>` follows whichever one the
cursor is on.

The reference has to start a token, so an address like `bob@example.com` stays
plain text. Trailing colons are split off greedily, so in `@a:b:10` only `10` is
the line number.

## Paths

In the file, reference paths are stored **absolute**: one notes file serves every
directory it is opened from, so a note has to mean the same file wherever it is
read. In the list buffer they are shown **relative to the cwd** wherever that
shortens them, and re-rendered when the cwd changes (`:cd`, `DirChanged`).

A relative path naming nothing on disk is left exactly as typed — `@param` in a
note about a Lua annotation is text, not a path waiting to be expanded.

## The list

`:Notes list` opens a scratch buffer (`keystone://notes`) in a height-pinned
split; the height you drag it to is remembered and reused the next time it opens.
It is deliberately *not* a buffer editing the notes file: no swap file to go
stale, no write hooks meant for real files, no unsaved-changes prompt on quit.
Its lines are the session's working copy.

Edit it like any other buffer; delete a note by deleting its line. The buffer is
written out whenever it stops being current (`BufLeave`) and on exit
(`VimLeavePre`), so `:w` is never needed and `:qa` never complains.

`<CR>` opens the reference under the cursor — at its line, or at the top of the
file when the reference names no line. With the cursor on prose rather than a
reference, `<CR>` does nothing.

Adding a note while the list buffer is live appends the line to the buffer rather
than to the file, so the two do not diverge, and writes the buffer out.

References are highlighted (`KeystoneNoteRef`, linked to `Directory` with
`default = true`) so they read apart from the prose.

### Completion

Typing `@` where a reference can start — at the beginning of a line or after
whitespace — opens path completion straight away. Elsewhere `@` is just a
character, so `bob@example.com` types normally. `<C-x><C-u>` triggers the same
completion by hand; outside an `@` token it cancels without leaving insert mode.

## Several Neovim instances

The notes file is shared, so instances are reconciled rather than allowed to
clobber each other.

Writes are atomic: the lines go to a temporary file beside the notes file and are
renamed into place, so a reader sees the old file or the new one, never half of
either.

Reads and writes are a three-way merge against the file as it stood when this
buffer was filled. Lines are matched by their exact text and counted, not by
position — notes are an unordered list, and an edited note reads as one line
deleted and another added, which is the right answer for free text. Merging
happens on write, on re-entering the list (`BufEnter`), and when the instance
regains focus (`FocusGained`). Unsaved edits in the buffer survive a merge and
stay unsaved.

A notes file that has gone missing is not treated as "every note was deleted" —
only a file that exists and is empty is.

## Lua API

```lua
local notes = require("keystone.notes")

notes.get_notes()      -- keystone.notes.Note[], in file order
notes.add_at_cursor()  -- prompt, then append a note anchored to the cursor line
notes.add_free()       -- prompt, then append a note with no location
notes.open_list()      -- open the list split
```

A `keystone.notes.Note` is `{ label = string, file = string?, lnum = integer? }`,
where `label` is the line exactly as it reads and `file`/`lnum` come from the
note's first reference. `get_notes` reads a live list buffer in preference to the
file, so it sees edits not yet written out.

---

[← All modules](../README.md#modules)
