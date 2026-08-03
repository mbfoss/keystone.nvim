# animate

Animates scroll commands across the intermediate positions instead of
jumping straight to the destination.

![Scrolling a file from top to bottom with animate enabled](assets/animate.gif)

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
