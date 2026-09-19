# scope

Draws a guide along the scope under the cursor, meaning the body of the function,
block or table the cursor is in. It can also draw a guide on every indent
level.

The scope comes from Treesitter: it is the smallest syntax node around the
cursor whose body is indented deeper than its first line. A cursor on a header
line (`function f()`, `if x then`) selects the body below it, and a cursor on
the closing line (`end`, `}`) selects the body above it. The buffer needs
Treesitter highlighting active; without it there is no scope, though indent
guides are still drawn.

Only the current window shows a scope.

## Configuration

```lua
require("keystone").setup({
  scope = {
    scope             = true,  -- guide along the scope under the cursor
    guides            = true,  -- guide on every indent level
    scope_char        = "│",   -- one cell wide
    guide_char        = "╎",   -- one cell wide
    exclude_filetypes = { "help", "markdown", "text", "gitcommit", "man", "checkhealth", "qf" },
  },
})
```

Guides are only drawn in ordinary file buffers. Trees, terminals and other
special buffers are left alone. Indent guides sit at the indents of the lines
enclosing each line, not at multiples of `'shiftwidth'`. The scope guide is
always drawn on one of those columns, so it never shows where an indent guide
would not. A blank line takes the larger indent of its neighbours. Comments
(lines starting with the leader of `'commentstring'`) do not open or close a
level, so one written left of its block does not break the guides.

## Highlights

Both groups are defined with `default = true`, so a colorscheme or your own
`nvim_set_hl` call wins over them.

| Group | Used for | Links to |
| --- | --- | --- |
| `KeystoneScope` | The scope guide | `NonText` |
| `KeystoneIndentGuide` | Indent guides | `NonText` |

## API

| Function | Purpose |
| --- | --- |
| `require("keystone.scope").get(win?)` | The scope at the cursor as `{ col, first, last }` (1-based lines), or nil |
| `require("keystone.scope").enable()` | Start drawing |
| `require("keystone.scope").disable()` | Stop drawing |
| `require("keystone.scope").toggle()` | Toggle drawing |
| `require("keystone.scope").is_enabled()` | Whether guides are being drawn |

## How it draws

Guides are ephemeral extmarks set from a decoration provider. Only the lines
being redrawn are computed, and nothing is stored in the buffer. Moving the
cursor does not redraw anything by itself, so when the scope changes, the rows
it covered and the rows it now covers are redrawn.

<!-- panvimdoc-ignore-start -->

---

[← All modules](../README.md#modules)

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
All modules: |keystone-modules|
-->
