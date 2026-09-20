# marksigns

Draws the name of every mark that is set (`ma`, `mA`, …) in the sign column of
its line, so a buffer's marks are visible without `:marks`.

Buffer-local marks (`a-z`) and file marks (`A-Z`) get their own highlight. Two
marks on one line share the sign; the sign column is two cells wide.

> **Requires Neovim ≥ 0.12.** The module is driven by the `MarkSet` event, which
> older versions do not have; on those it warns once and stays inert.

## Configuration <!-- tag: configuration -->

```lua
require("keystone").setup({
  marksigns = {
    marks         = "abcdefghijklmnopqrstuvwxyz", -- which marks to sign, most significant first
    combine       = true,                         -- pack two names into one sign
    hl_local      = "KeystoneMarkSignsLocal",     -- highlight for a-z marks
    hl_global     = "KeystoneMarkSignsGlobal",    -- highlight for A-Z marks
    sign_priority = 5,                            -- sign priority against other plugins
  },
})
```

`marks` is both the filter and the ordering: only the names it lists are signed,
in the order given. Signs are drawn only in ordinary file buffers.

## Highlights <!-- tag: highlights -->

Both groups are defined with `default = true`, so a colorscheme or your own
`nvim_set_hl` call wins over them.

| Group | Marks | Links to |
| --- | --- | --- |
| `KeystoneMarkSignsLocal` | `a-z` | `DiagnosticHint` |
| `KeystoneMarkSignsGlobal` | `A-Z` | `DiagnosticInfo` |

## API <!-- tag: api -->

| Function | Purpose |
| --- | --- |
| `require("keystone.marksigns").refresh(bufnr?)` | Recompute a buffer's signs now |
| `require("keystone.marksigns").enable()` | Start drawing signs |
| `require("keystone.marksigns").disable()` | Stop, and remove the signs already placed |
| `require("keystone.marksigns").is_enabled()` | Whether signs are being drawn |

## How it stays current <!-- tag: updates -->

`MarkSet` covers every explicit change (`m`, `:mark`, `nvim_buf_set_mark()`,
`:delmarks`, `nvim_buf_del_mark()`) and names the mark, so only its buffer is
recomputed. File marks are the exception: they move between buffers and the old
buffer gets no event, so all buffers are redone.

The event does not report deleting the line a mark sits on, which drops the mark
silently; `TextChanged` and `InsertLeave` catch that with a debounced recompute.

<!-- panvimdoc-ignore-start -->

---

[← All modules](../README.md#modules)

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
All modules: |keystone-modules|
-->
