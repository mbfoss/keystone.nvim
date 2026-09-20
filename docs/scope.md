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
    scope_blend       = 25,    -- percent the scope guide fades into the background
    guide_blend       = 50,    -- percent the indent guides fade into the background
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

Both groups are defined with `default = true`, so a colorscheme or your own
`nvim_set_hl` call wins over them.

| Group | Used for | Links to |
| --- | --- | --- |
| `KeystoneScope` | The scope guide | `NonText` |
| `KeystoneIndentGuide` | Indent guides | `KeystoneScope` |

`scope_blend` and `guide_blend` fade a guide into the background: 0 keeps its own
colour, 100 leaves it the background's. By default the scope guide is the heavier
character faded 25 percent and the indent guides the lighter one faded 50.

Neovim's `blend=` attribute only takes effect in floats and the popup menu, so
the fade is baked into a colour instead: the group's foreground is mixed that far
into the background of `Normal` and kept in `KeystoneScopeBlend` or
`KeystoneIndentGuideBlend`, recomputed on every colorscheme change. Setting a
blend therefore leaves `KeystoneScope` and `KeystoneIndentGuide` free to define
as usual. Only the foreground is taken; a background would paint a block behind
every guide cell, and `NonText` carries one under some colorschemes.

The mix is a 24-bit colour, so it only reaches the screen where Neovim draws with
`gui` attributes: a TUI with `'termguicolors'`, or an external UI attached with
`rgb`. Elsewhere the blended group renders from its `cterm` attributes, which
carry no fade, so the characters alone tell the guides apart — a dashed
`guide_char` like `╎` helps there. A source group with no foreground is drawn
unblended. The mix is against `Normal`, so a window with another background
through `'winhighlight'` fades towards the wrong colour.

## API <!-- tag: api -->

| Function | Purpose |
| --- | --- |
| `require("keystone.scope").get(win?)` | The scope at the cursor as `{ col, first, last }` (1-based lines), or nil |
| `require("keystone.scope").enable()` | Start drawing |
| `require("keystone.scope").disable()` | Stop drawing |
| `require("keystone.scope").toggle()` | Toggle drawing |
| `require("keystone.scope").is_enabled()` | Whether guides are being drawn |

## How it draws <!-- tag: drawing -->

Guides are ephemeral extmarks set from a decoration provider: only the lines
being redrawn are computed, and nothing is stored in the buffer. Cursor movement
redraws nothing by itself, so when the scope changes the rows it covered and the
rows it now covers are redrawn.

<!-- panvimdoc-ignore-start -->

---

[← All modules](../README.md#modules)

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
All modules: |keystone-modules|
-->
