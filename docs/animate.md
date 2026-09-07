# animate

Animates scroll commands across the intermediate positions instead of
jumping straight to the destination.

<!-- panvimdoc-ignore-start -->

![Scrolling a file from top to bottom with animate enabled](https://raw.githubusercontent.com/mbfoss/keystone.nvim/refs/heads/assets/animate.gif)

<!-- panvimdoc-ignore-end -->

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

<!-- panvimdoc-ignore-start -->

---

[← All modules](../README.md#modules)

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
All modules: |keystone-modules|
-->
