# clue

A popup listing the keys that can follow a trigger, shown `delay` milliseconds
after the trigger. Default triggers: `<leader>`, `g`, `z`, `'`, `` ` `` and `"`
in normal and visual mode; `[`, `]` and `<C-w>` in normal mode; `<C-x>` in insert
mode; `<C-r>` in insert and command-line mode.

<!-- panvimdoc-ignore-start -->

![The follow-up-key popup after pressing g](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/clue.gif)

<!-- panvimdoc-ignore-end -->

## Configuration <!-- tag: configuration -->

```lua
require("keystone").setup({
  clue = {
    delay = 300,          -- ms before the popup appears
    border = "rounded",
    max_desc_width = 40,  -- crop long descriptions with …
    preset = true,        -- register built-in g/z/window descriptions
    builtin = { marks = true, registers = true },
    -- triggers = { ... } -- override the default trigger list
  },
})
```

## API <!-- tag: api -->

Add your own group/label descriptions:

```lua
require("keystone.clue").add(...)
```

<!-- panvimdoc-ignore-start -->

---

[← All modules](../README.md#modules)

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
All modules: |keystone-modules|
-->
