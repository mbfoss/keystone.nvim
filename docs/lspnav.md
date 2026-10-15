# lspnav

Motions to the next and previous function or type of a buffer, read from the
server's own `textDocument/documentSymbol` tree.

Neovim's LSP defaults rename, list references and jump to a definition, but no
motion moves between definitions. These do, and because the whole tree is walked,
nested and local definitions are stops too. What counts as a function is the
server's answer, not a pattern match on the line.

## Scope <!-- tag: scope -->

- **It maps nothing.** The module exposes functions, and that is all: no keymap,
  no autocmd, no user command. Mapping them is your call, and the examples below
  are the recommended ones. What `setup()` does is record the kind lists the
  actions read, so `lspnav = true` alone changes no visible behaviour.
- **It asks one client.** The first attached client serving
  `textDocument/documentSymbol`, the same one the symbol tree uses. With two
  servers attached, a symbol only the second one knows about is not a stop.
- **It does not need `lspsetup`.** Any attached client with document symbols is
  enough, however it was enabled.

## Configuration <!-- tag: configuration -->

```lua
require("keystone").setup({
  lspnav = {
    function_kinds = { 6, 9, 12 },             -- Method, Constructor, Function
    type_kinds     = { 2, 3, 5, 10, 11, 23 },  -- Module, Namespace, Class,
                                               -- Enum, Interface, Struct
  },
})
```

Both are lists of LSP `SymbolKind` numbers, and each list replaces the default
wholesale rather than merging into it.

## Actions <!-- tag: actions -->

| Action | Stops on | Signature |
| --- | --- | --- |
| `next_function` | `Method`, `Constructor`, `Function` | `next_function(bufnr?, count?)` |
| `prev_function` | `Method`, `Constructor`, `Function` | `prev_function(bufnr?, count?)` |
| `next_type` | `Module`, `Namespace`, `Class`, `Enum`, `Interface`, `Struct` | `next_type(bufnr?, count?)` |
| `prev_type` | `Module`, `Namespace`, `Class`, `Enum`, `Interface`, `Struct` | `prev_type(bufnr?, count?)` |

`bufnr` defaults to the current buffer. `count` defaults to `vim.v.count1`, so the
functions work unchanged under a mapping with a count:

```lua
for lhs, action in pairs({
  ["]f"] = "next_function",
  ["[f"] = "prev_function",
  ["]c"] = "next_type",
  ["[c"] = "prev_type",
}) do
  vim.keymap.set("n", lhs, function()
    require("keystone.lspnav")[action]()
  end, { desc = "keystone.lspnav" })
end
```

`jump(direction, kinds, bufnr?, count?)` takes a kind list of your own, for a stop
the config has no group for:

```lua
require("keystone.lspnav").jump("next", { 5, 11 })  -- next class or interface
```

## Semantics <!-- tag: semantics -->

- **Position, not line.** Candidates are compared on line and column, so two
  definitions on one line stay distinct.
- **The definition under the cursor counts as neither direction.** Pressing
  the same action twice moves past it, rather than sticking to the definition
  you are in.
- **A count past the end stops at the end**, like a Vim motion with an
  oversized count.
- **Silence at the edges.** At the first or last match, and when no capable
  client is attached, an action does nothing and reports nothing.

<!-- panvimdoc-ignore-start -->

---

[← All modules](../README.md#modules)

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
All modules: |keystone-modules|
-->
