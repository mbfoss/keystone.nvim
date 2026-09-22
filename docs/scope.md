# scope

Draws a guide along the scope under the cursor — the body of the function, block
or table it is in — and a guide on every indent level. Both are on by default and
can be turned off separately.

<!-- panvimdoc-ignore-start -->

![The scope guide along the block under the cursor, with indent guides on every level](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/scope.png)

<!-- panvimdoc-ignore-end -->

The scope comes from Treesitter: the smallest syntax node around the cursor whose
body is indented deeper than its first line. A cursor on a header line
(`function f()`, `if x then`) selects the body below it; one on the closing line
(`end`, `}`) selects the body above. Without Treesitter highlighting there is no
scope, though indent guides are still drawn. Only the current window shows a
scope.

## Configuration <!-- tag: configuration -->

```lua
require("keystone").setup({
  scope = {
    scope             = true,  -- guide along the scope under the cursor
    guides            = true,  -- guide on every indent level
    scope_char        = "┃",   -- one cell wide
    guide_char        = "│",   -- one cell wide
    exclude_filetypes = { "help", "markdown", "text", "gitcommit", "man", "checkhealth", "qf" },
  },
})
```

Guides are drawn only in ordinary file buffers. Indent guides sit at the indents
of the enclosing lines, not at multiples of `'shiftwidth'`, and the scope guide
always lands on one of those columns. A blank line takes the larger indent of its
neighbours. Comments (lines starting with the `'commentstring'` leader) do not
open or close a level, so one written left of its block does not break the
guides.

## Highlights <!-- tag: highlights -->

The guides are drawn with the groups below. Each `default`-links to its
`…Default` group, so a colorscheme or an `nvim_set_hl` call on it takes
precedence.

| Group | Used for | Defaults to |
| --- | --- | --- |
| `KeystoneScope` | The scope guide | `KeystoneScopeDefault` |
| `KeystoneIndentGuide` | Indent guides | `KeystoneIndentGuideDefault` |

The `…Default` groups are rebuilt on every colorscheme change; override the two
groups above instead.

| Group | Is |
| --- | --- |
| `KeystoneScopeDefault` | `NonText` faded 25% into the background |
| `KeystoneIndentGuideDefault` | `NonText` faded 50% into the background |

## API <!-- tag: api -->

| Function | Purpose |
| --- | --- |
| `require("keystone.scope").get(win?)` | The scope at the cursor as `{ col, first, last }` (1-based lines), or nil |
| `require("keystone.scope").enable()` | Start drawing |
| `require("keystone.scope").disable()` | Stop drawing |
| `require("keystone.scope").toggle()` | Toggle drawing |
| `require("keystone.scope").is_enabled()` | Whether guides are being drawn |

## How it draws <!-- tag: drawing -->

Guides are drawn as ephemeral extmarks, so they are never part of the buffer's
content: nothing is inserted and nothing is written to disk.

<!-- panvimdoc-ignore-start -->

---

[← All modules](../README.md#modules)

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
All modules: |keystone-modules|
-->
