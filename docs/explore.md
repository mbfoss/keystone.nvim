# explore

A file selector for navigating the filesystem.

![Descending through directories with the preview pane on](https://raw.githubusercontent.com/mbfoss/keystone.nvim/assets/explore.gif)

Each entry carries its size and modification time in a right-hand column, laid
out like `ls -lh` — digits right-aligned, unit in its own slot, the day
space-padded — so the values read as columns rather than ragged text:

```
  subdir                              Aug 12 09:47
  notes.md                     500 B  Aug 12 09:47
  archive.tar.gz               2.9 MB Aug  5 09:05
  vendor.log                1022.5 KB Nov 22  2019
```

Directories show no size. Timestamps within the last six months show a clock,
older ones show the year, the way `ls -l` switches.

## Configuration

```lua
require("keystone").setup({ explore = true })
```

Or, to change what the detail column shows:

```lua
require("keystone").setup({
  explore = {
    detail_fields = { "size", "mtime" }, -- per-entry details, in the order given
  },
})
```

`detail_fields` is both the filter and the ordering: only the fields it lists
are shown, in the order listed. Set it to `{}` to turn the column off entirely.

| Field | Shows |
| --- | --- |
| `size` | Human-readable file size (`500 B`, `2.9 MB`, `1.0 GB`) |
| `mtime` | Modification time (`Aug 12 09:47`, `Nov 22  2019`) |

Names are cropped to fit before the detail column, so a long filename can never
push a value out of alignment. In a window too narrow to afford both, names win
and the details are dropped.

## Commands

| Command | What it does |
| --- | --- |
| `:FileSelector` | Open the file selector |

---

[← All modules](../README.md#modules)
