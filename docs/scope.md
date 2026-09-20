# scope

Draws a guide along the scope under the cursor, meaning the body of the function,
block or table the cursor is in, and a guide on every indent level. Each is
enabled by default and can be turned off on its own.

<!-- panvimdoc-ignore-start -->

![The scope guide along the block under the cursor, with indent guides on every level](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/scope.png)

<!-- panvimdoc-ignore-end -->

The scope comes from Treesitter: it is the smallest syntax node around the
cursor whose body is indented deeper than its first line. A cursor on a header
line (`function f()`, `if x then`) selects the body below it, and a cursor on
the closing line (`end`, `}`) selects the body above it. The buffer needs
Treesitter highlighting active; without it there is no scope, though indent
guides are still drawn.

Only the current window shows a scope.

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

Guides are only drawn in ordinary file buffers. Trees, terminals and other
special buffers are left alone. Indent guides sit at the indents of the lines
enclosing each line, not at multiples of `'shiftwidth'`. The scope guide is
always drawn on one of those columns, so it never shows where an indent guide
would not. A blank line takes the larger indent of its neighbours. Comments
(lines starting with the leader of `'commentstring'`) do not open or close a
level, so one written left of its block does not break the guides.

## Highlights <!-- tag: highlights -->

Both groups are defined with `default = true`, so a colorscheme or your own
`nvim_set_hl` call wins over them.

| Group | Used for | Links to |
| --- | --- | --- |
| `KeystoneScope` | The scope guide | `NonText` |
| `KeystoneIndentGuide` | Indent guides | `KeystoneScope` |

`scope_blend` and `guide_blend` fade a guide into the background: 0 keeps its
own colour, 100 leaves it the colour of the background. By default the scope
guide is the heavier character faded 25 percent and the indent guides the
lighter one faded 50 percent, so the scope reads as the same column the indent
guides draw, only nearer the front.

Neovim's `blend=` highlight attribute only takes effect in floating windows and
the popup menu, so the fade is baked into a colour instead. The group's
foreground is mixed that far into the background of `Normal` and kept in a
group of its own, `KeystoneScopeBlend` or `KeystoneIndentGuideBlend`,
recomputed from the source group on every colorscheme change. Setting a blend
therefore leaves `KeystoneScope` and `KeystoneIndentGuide` free for you or your
colorscheme to define as usual.

Only the foreground is taken. A guide is a single cell of virtual text, so a
background of the source group's would paint a block behind every one of them,
and `NonText`, the default source, carries one under some colorschemes
(`desert` among them).

The mix is a 24-bit colour, so it only reaches the screen where Neovim draws
with `gui` attributes: a TUI with `'termguicolors'` set, or an external UI
attached with `rgb`. On a terminal without it the blended group is still
defined but rendered from its `cterm` attributes, which carry no fade, so the
guides keep their own colour and the characters alone tell them apart; a
dashed `guide_char` like `╎` sets the indent guides further back there.
When the source group has no foreground to mix, the guides are drawn with it
unblended. The mix is against `Normal`, so a window given another background
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
