# filetree

A file explorer in a side window.

![Creating a directory and a file, renaming, marking files to move and copy, deleting, and the help float](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/filetree.gif)

## Configuration

```lua
require("keystone").setup({
  filetree = {
    width_ratio = 0.2,             -- fraction of the editor width
    follow_current_buffer = false, -- reveal the current file as you switch buffers
  },
})
```

Or standalone:

```lua
require("keystone.filetree").setup({ width_ratio = 0.2 })
```

## Commands

| Command | What it does |
| --- | --- |
| `:FileTree` | Toggle the side window |
| `:FileTree open` | Open it |
| `:FileTree close` | Close it |
| `:FileTree toggle` | Same as no argument |

## Keymaps

Buffer-local, inside the tree window. `g?` shows the same list in a float.

| Key | What it does |
| --- | --- |
| `<CR>` | Open file / toggle directory |
| `za` / `zc` / `zo` | Toggle / collapse / expand |
| `zC` / `zO` | Collapse / expand recursively |
| `a` / `A` | Create file / directory next to the item under the cursor |
| `i` / `I` | Create file / directory inside the directory under the cursor |
| `r` | Rename the item under the cursor |
| `<Tab>` | Toggle selection of the item under the cursor (also in visual mode, over a range) |
| `<S-Tab>` | Clear the selection |
| `x` / `c` | Move / copy the selected items into the directory under the cursor |
| `d` | Delete the selected items to the system trash |
| `D` | Delete the selected items permanently |
| `gb` | Reveal the previous buffer |
| `gh` | Toggle hidden files |
| `K` | Hover info (type, size, modified) |
| `R` | Refresh the tree |
| `g?` | Show the help float |

## File manipulation

Everything below acts on real files on disk. The tree refreshes the affected
directories afterwards and reveals the result.

### Creating

`a` and `A` create next to the item under the cursor — in its parent directory,
whether that item is a file or a directory. `i` and `I` create *inside* it when
it is a directory (and in its parent otherwise), which is how you add the first
entry to an empty directory.

Each prompts for a name and validates as you type: the name may not be empty and
may not contain path separators — it always lands in the chosen directory, so
you cannot type your way out of it. Files are created empty (`0644`),
directories with mode `0755`. An existing name is an error, never an overwrite.

### Renaming

`r` prompts with the current name filled in, and renames in place — the same
validation applies, so a rename cannot move the item to another directory. Two
things happen alongside the rename:

- **LSP is told.** Every attached client supporting `workspace/willRenameFiles`
  is asked first and its workspace edit applied (so imports referring to the old
  path get rewritten), and clients supporting `workspace/didRenameFiles` are
  notified after.
- **Open buffers follow.** A buffer on the old path is swapped for one on the
  new path in every window showing it, and the stale buffer is deleted.

### Moving and copying

Mark items with `<Tab>` (or over a visual range), then put the cursor on the
destination and press `x` to move or `c` to copy. The destination is the item
under the cursor when it is a directory, otherwise its parent directory. A
confirmation lists the sources and the destination before anything is touched.

Selection is not limited to one directory — you can mark items across the whole
tree and land them in one place. The selection is cleared once the transfer runs.

Operations that would misbehave are dropped from the batch rather than
attempted:

| Case | Result |
| --- | --- |
| The item is the tree root | Skipped |
| Copying into the directory it already lives in | Duplicated as `name copy`, then `name copy 2`, … |
| Moving into the directory it already lives in | No-op |
| Moving or copying a directory into itself or a descendant | Skipped, with a warning |
| The name already exists in the destination | Skipped, with a warning — never overwritten |

Moves use `rename(2)` and so carry the same LSP and buffer handling as `r`
above. Copies are recursive: directories are walked and recreated, symlinks are
copied as links (the link is duplicated, not its target).

### Deleting

`d` moves the selected items to the system trash; `D` deletes them permanently.
Both are recursive for directories and both confirm first, listing every path.
The tree root is never deleted.

Trash support is resolved per platform: `trash` or Finder via `osascript` on
macOS, the Recycle Bin via PowerShell on Windows, and `gio trash` / `trash-put`
/ `trash` on other unices. When none is available, `d` warns and falls back to a
permanent delete for that invocation.

Unlike rename and move, deletion tells LSP nothing and leaves open buffers
alone — a buffer on a deleted file stays loaded with its contents.

### External changes

Visible directories are monitored, so files created, renamed, or removed outside
Neovim show up without any action. `R` forces a full reload if a change is
missed.

---

[← All modules](../README.md#modules)
