# clue

A which-key style popup that shows the available continuation keys a short
moment after you press a trigger (`<leader>`, `g`, `z`, marks, registers,
window commands, and more).

## Configuration

```lua
require("keystone").setup({
  clue = {
    delay = 300,          -- ms before the popup appears
    border = "rounded",
    max_desc_width = 40,  -- crop long descriptions with …
    preset = true,        -- register built-in g/z/window descriptions
    builtin = { marks = true, registers = true },
    -- triggers = { ... } -- override the default trigger list if you like
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
