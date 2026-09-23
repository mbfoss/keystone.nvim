# filetree

A file explorer in a side window.

<!-- panvimdoc-ignore-start -->

![Creating a directory and a file, renaming, marking files to move and copy, deleting, and the help float](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/filetree.gif)

<!-- panvimdoc-ignore-end -->

## Configuration <!-- tag: configuration -->

```lua
require("keystone").setup({
  filetree = {
    width_ratio = 0.2,             -- fraction of the editor width (left/right)
    height_ratio = 0.2,            -- fraction of the editor height (top/bottom)
    position = "left",             -- side the window opens on
                                   -- ("top"|"bottom"|"left"|"right")
    follow_current_buffer = false, -- reveal the current file as you switch buffers
  },
})
```

Or standalone:

```lua
require("keystone.filetree").setup({ width_ratio = 0.2 })
```

## Commands <!-- tag: commands -->

| Command | What it does |
| --- | --- |
| `:FileTree [dir]` | Open the side window, or reveal the current file in it. With `dir`, set the tree root to `dir` first |

## Keymaps <!-- tag: keymaps -->

Buffer-local, inside the tree window. `g?` shows the same list in a float.

| Key | What it does |
| --- | --- |
| `<CR>` | Open file / toggle directory |
| `o` | Open file, keeping focus in the tree |
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

## File manipulation <!-- tag: files -->

Everything below acts on real files on disk. The tree refreshes the affected
directories and reveals the result.

### Creating <!-- tag: creating -->

`a` and `A` create next to the item under the cursor, in its parent directory,
whether that item is a file or a directory. `i` and `I` create *inside* it when
it is a directory (and in its parent otherwise), which is how you add the first
entry to an empty directory.

Each prompts for a name and validates as you type: not empty, no path
separators, so the result always lands in the chosen directory. Files are created
empty (`0644`), directories `0755`. An existing name is an error, never an
overwrite.

### Renaming <!-- tag: renaming -->

`r` prompts with the current name filled in and renames in place, under the same
validation, so a rename cannot move the item elsewhere. Alongside it:

- **LSP is told.** Clients supporting `workspace/willRenameFiles` are asked first
  and their workspace edit applied (rewriting imports of the old path); clients
  supporting `workspace/didRenameFiles` are notified after.
- **Open buffers follow.** A buffer on the old path is swapped for one on the new
  path in every window showing it, and the stale buffer is deleted.

### Moving and copying <!-- tag: move-copy -->

Mark items with `<Tab>` (or over a visual range), then put the cursor on the
destination and press `x` to move or `c` to copy. The destination is the item
under the cursor when it is a directory, otherwise its parent. A confirmation
lists the sources and destination first.

The selection can span the whole tree, and is cleared once the transfer runs.
Operations that would misbehave are dropped from the batch:

| Case | Result |
| --- | --- |
| The item is the tree root | Skipped |
| Copying into the directory it already lives in | Duplicated as `name copy`, then `name copy 2`, … |
| Moving into the directory it already lives in | No-op |
| Moving or copying a directory into itself or a descendant | Skipped, with a warning |
| The name already exists in the destination | Skipped, with a warning; never overwritten |

Moves use `rename(2)` and carry the same LSP and buffer handling as `r`. Copies
are recursive; symlinks are copied as links, not as their target.

### Deleting <!-- tag: deleting -->

`d` moves the selected items to the system trash; `D` deletes them permanently.
Both are recursive for directories and both confirm first, listing every path.
The tree root is never deleted.

Trash support is resolved per platform: `trash` or Finder via `osascript` on
macOS, the Recycle Bin via PowerShell on Windows, `gio trash` / `trash-put` /
`trash` elsewhere. With none available, `d` errors and deletes nothing; use `D`.

Unlike rename and move, deletion tells LSP nothing and leaves open buffers
loaded with their contents.

### External changes <!-- tag: external -->

Visible directories are monitored, so changes made outside Neovim show up on
their own. `R` forces a full reload if one is missed.

<!-- panvimdoc-ignore-start -->

---

[← All modules](../README.md#modules)

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
All modules: |keystone-modules|
-->
