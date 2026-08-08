# marksigns

Draws the name of every mark that is set — `ma`, `mA`, … — in the sign column of
the line holding it, so the marks in a buffer are visible without `:marks`.

Buffer-local marks (`a-z`) and file marks (`A-Z`) get their own highlight. When
two marks share a line, both names go in the one sign; the sign column is two
cells wide.

> **Requires Neovim ≥ 0.12.** The module is driven by the `MarkSet` event, which
> older versions do not have; on those it warns once and stays inert.

## Configuration

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
and when several land on the same line they appear in the order given there.

Signs are only drawn in ordinary file buffers — trees, terminals and other
special buffers are left alone.

## Highlights

Both groups are defined with `default = true`, so a colorscheme or your own
`nvim_set_hl` call wins over them.

| Group | Marks | Links to |
| --- | --- | --- |
| `KeystoneMarkSignsLocal` | `a-z` | `DiagnosticHint` |
| `KeystoneMarkSignsGlobal` | `A-Z` | `DiagnosticInfo` |

## API

| Function | Purpose |
| --- | --- |
| `require("keystone.marksigns").refresh(bufnr?)` | Recompute a buffer's signs now |
| `require("keystone.marksigns").enable()` | Start drawing signs |
| `require("keystone.marksigns").disable()` | Stop, and remove the signs already placed |
| `require("keystone.marksigns").is_enabled()` | Whether signs are being drawn |

## How it stays current

`MarkSet` covers every explicit change — a mark set with `m`, `:mark` or
`nvim_buf_set_mark()`, and one deleted with `:delmarks` or
`nvim_buf_del_mark()` — and names the mark, so the buffer that owns it is the
only one recomputed. A file mark is the exception: it moves between buffers, and
the buffer that used to hold it gets no event, so all of them are redone.

One change the event does not report is deleting the line a mark sits on, which
drops the mark silently. `TextChanged` and `InsertLeave` catch that with a
debounced recompute of the whole buffer.

---

[← All modules](../README.md#modules)
