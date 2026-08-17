# clue

A popup listing the keys that can follow a trigger, shown after the trigger has
been held for `delay` milliseconds. The default triggers are `<leader>`, `g` and
`z` in normal and visual mode; `'` and `` ` `` (marks) and `"` (registers) in
both; `[`, `]` and `<C-w>` in normal mode; `<C-x>` in insert mode; and `<C-r>` in
insert and command-line mode.

![The follow-up-key popup after pressing g](https://raw.githubusercontent.com/mbfoss/keystone.nvim/assets/clue.gif)

## Configuration

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

## API

Add your own group/label descriptions:

```lua
require("keystone.clue").add(...)
```

---

[← All modules](../README.md#modules)
