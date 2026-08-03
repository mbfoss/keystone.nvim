# animate

Smooth animated scrolling.

## Configuration

```lua
require("keystone").setup({
  animate = {
    speed    = 20,  -- ms per line
    duration = 300, -- hard cap on animation length, in ms
    step     = 16,  -- frame interval in ms
    -- filter = function(buf) ... end, -- return false to skip a buffer
    -- easing = function(i) ... end,
  },
})
```

---

[← All modules](../README.md#modules)
