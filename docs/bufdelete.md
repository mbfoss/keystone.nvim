# bufdelete

Delete a buffer without collapsing the window layout.

`:bdelete` closes every window that happens to be showing the buffer, so
deleting a file from a split layout takes the split with it. This module points
those windows at another buffer first, then deletes — the layout is untouched.

## Configuration

```lua
require("keystone").setup({ bufdelete = true })
```

```lua
require("keystone").setup({
  bufdelete = {
    ignore_floats            = true,  -- keep buffers shown in a floating window
    ignore_file_types        = {},    -- keep these filetypes
    ignore_filename_patterns = {},    -- keep names matching these Lua patterns
    ignore_alt_file          = false, -- keep the alternate file (`#`)
    ignore_special_buffers   = true,  -- keep buffers with a non-empty `buftype`
  },
})
```

## What gets kept

The `ignore_*` options describe buffers a **bulk** selection must leave alone:

| Option | Keeps |
| --- | --- |
| `ignore_floats` | buffers displayed in a floating window |
| `ignore_file_types` | buffers whose `filetype` is in the list |
| `ignore_filename_patterns` | buffers whose full name matches a Lua pattern |
| `ignore_alt_file` | the alternate file (`#`), so `<C-^>` still goes somewhere |
| `ignore_special_buffers` | any buffer with a non-empty `buftype` — help, quickfix, terminal, prompt |

```lua
require("keystone").setup({
  bufdelete = {
    ignore_file_types        = { "gitcommit", "gitrebase" },
    ignore_filename_patterns = { "%.env$", "/node_modules/" },
  },
})
```

They apply whenever a **set** is selected — a glob, `:Bdeletehidden`, or
`delete_many`.
They do **not** block a buffer you name: `:Bdelete` on the current buffer,
`:Bdelete foo.lua`, or `:3Bdelete` deletes the named target, since the selection
is already explicit. Pass `{ ignore = true }` to `delete()` to opt
a single delete into the rules, or `{ ignore = false }` to a bulk call to sweep
past them.

Buffers kept this way are reported as a count, separately from buffers kept
because of unsaved changes — the second is a warning, the first is not.

`M.ignore_reason(bufnr)` returns why a buffer would be kept, or `nil`.

## Commands

Four commands, named after the built-ins whose semantics they keep.

```vim
:Bdelete            " current buffer
:Bdelete *          " every listed buffer
:Bdelete *.log      " glob on buffer names
:Bdelete foo.lua    " one named buffer
:3Bdelete           " buffer 3
:Bwipeout *         " the same sets, with :bwipeout semantics
:Bdeletehidden      " every buffer no window is showing
:Bwipeouthidden     " the same set, with :bwipeout semantics
```

Add `!` to any of them to force past unsaved changes.

The argument to `:Bdelete`/`:Bwipeout` is *always* a buffer name or a glob over
buffer names — there are no keywords, so a buffer called `all` is nothing
special and `:Bdelete all` deletes it. `:Bdeletehidden`/`:Bwipeouthidden` take no
argument at all: their selection is fixed.

Hidden means *no* window in *any* tabpage is showing the buffer. A buffer sitting
in a split two tabs over is not hidden and survives.

Globs are matched against the full path, the path relative to the cwd, and the
final component, so `*.log`, `src/*.lua` and `init.lua` all do the expected
thing. Completion offers `*` and the names of listed buffers.

### Unsaved changes

No command discards an edit. A buffer that is modified — or is a terminal — is
left alone and reported: `:Bwipeout *` with one dirty buffer among ten wipes the
nine and keeps the tenth, still listed and still on screen.

`!` (`:Bdelete! *`, `:Bwipeout! *`, `:Bdeletehidden!`) is the explicit override that
throws the changes away, exactly as `:bdelete!` does.

The guard sits below the delete/wipe split rather than in either command, so the
two cannot drift apart. If a delete is refused for some other reason after the
buffer has been swapped out of its windows — a `BufUnload` autocmd, `'confirm'`
— the buffer is put back in those windows rather than left orphaned.

## What replaces the buffer

Each window showing the deleted buffer gets, in order of preference:

1. that window's own alternate file (`#`), if it is still a listed buffer,
2. otherwise the most recently used listed buffer,
3. otherwise a single empty buffer, shared by every window that needs one — so
   `:Bdelete *` on a four-way split leaves four windows on one empty buffer,
   not four empty buffers.

A floating window is not part of a layout worth preserving, so when its buffer
is deleted anyway — an explicit `:Bdelete`, or `ignore_floats = false` — the
float is closed rather than repointed. The exception is a float that is the only
window in its tabpage, which would take the tabpage with it.

## Delete or wipe

`:bdelete` unlists the buffer and unloads its contents, but keeps the buffer
object, its number, and its marks — reopening the file lands you back where you
were. `:bwipeout` destroys it outright: the number is freed and the marks are
gone. Use `:Bwipeout` when the buffer should be discarded outright (a stale
terminal, a renamed file, a session reset), and `:Bdelete` otherwise.

## Lua API

```lua
local bufdelete = require("keystone.bufdelete")

bufdelete.delete()                          -- current buffer, layout preserved
bufdelete.delete(bufnr, { force = true })   -- discard unsaved changes
bufdelete.delete(bufnr, { wipe = true })    -- `:bwipeout` semantics for this call
                                            -- (still refuses a modified buffer)
bufdelete.delete_many({ 3, 7 })             -- one operation, so neither replaces the other
bufdelete.delete_matching("*.log")          -- the glob behind `:Bdelete *.log`
bufdelete.delete_all({ ignore = false })    -- sweep past the ignore rules
bufdelete.delete_others()                   -- returns how many were deleted
bufdelete.delete_hidden()                   -- the sweep behind `:Bdeletehidden`
bufdelete.delete_hidden({ wipe = true })    -- ...and behind `:Bwipeouthidden`
bufdelete.delete_all()

bufdelete.listed()                          -- listed buffers, most recently used first
bufdelete.hidden()                          -- listed buffers no window shows
bufdelete.matching("*.log")                 -- listed buffers a glob matches
bufdelete.is_ignored(bufnr)                 -- would a bulk delete keep this one?
bufdelete.ignore_reason(bufnr)              -- ...and why
```

Mappings, if you want them:

```lua
vim.keymap.set("n", "<leader>bd", "<Cmd>Bdelete<CR>")
vim.keymap.set("n", "<leader>bh", "<Cmd>Bdeletehidden<CR>")
vim.keymap.set("n", "<leader>bo", function() require("keystone.bufdelete").delete_others() end)
```

---

[← All modules](../README.md#modules)
