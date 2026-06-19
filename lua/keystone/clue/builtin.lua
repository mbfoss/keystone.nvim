--- Built-in (non-mapped) key sequences worth hinting. These are *virtual* clue
--- entries: `keystone.clue` never executes them — Neovim runs the built-in as
--- usual — they exist only so the clue window has something to show for prefixes
--- like `<C-w>`, `z` and `g` that are not backed by user mappings.
---@type keystone.clue.Clue[]
return {
    -- window commands (<C-w>)
    { mode = "n", keys = "<C-w>s", desc = "split" },
    { mode = "n", keys = "<C-w>v", desc = "vsplit" },
    { mode = "n", keys = "<C-w>w", desc = "next window" },
    { mode = "n", keys = "<C-w>p", desc = "previous window" },
    { mode = "n", keys = "<C-w>q", desc = "quit window" },
    { mode = "n", keys = "<C-w>c", desc = "close window" },
    { mode = "n", keys = "<C-w>o", desc = "only window" },
    { mode = "n", keys = "<C-w>h", desc = "go left" },
    { mode = "n", keys = "<C-w>j", desc = "go down" },
    { mode = "n", keys = "<C-w>k", desc = "go up" },
    { mode = "n", keys = "<C-w>l", desc = "go right" },
    { mode = "n", keys = "<C-w>x", desc = "swap window" },
    { mode = "n", keys = "<C-w>=", desc = "equalize" },
    { mode = "n", keys = "<C-w>_", desc = "max height" },
    { mode = "n", keys = "<C-w>|", desc = "max width" },
    { mode = "n", keys = "<C-w>T", desc = "to new tab" },

    -- folds / scroll (z)
    { mode = "n", keys = "zz", desc = "center cursor" },
    { mode = "n", keys = "zt", desc = "cursor to top" },
    { mode = "n", keys = "zb", desc = "cursor to bottom" },
    { mode = "n", keys = "za", desc = "toggle fold" },
    { mode = "n", keys = "zo", desc = "open fold" },
    { mode = "n", keys = "zc", desc = "close fold" },
    { mode = "n", keys = "zR", desc = "open all folds" },
    { mode = "n", keys = "zM", desc = "close all folds" },
    { mode = "n", keys = "zf", desc = "create fold" },

    -- g commands
    { mode = "n", keys = "gg", desc = "first line" },
    { mode = "n", keys = "gd", desc = "goto definition" },
    { mode = "n", keys = "gD", desc = "goto declaration" },
    { mode = "n", keys = "gi", desc = "last insert" },
    { mode = "n", keys = "gv", desc = "reselect" },
    { mode = "n", keys = "gj", desc = "down (display line)" },
    { mode = "n", keys = "gk", desc = "up (display line)" },
    { mode = "n", keys = "g;", desc = "older change" },
    { mode = "n", keys = "g,", desc = "newer change" },
    { mode = "n", keys = "gu", desc = "lowercase" },
    { mode = "n", keys = "gU", desc = "uppercase" },
    { mode = "n", keys = "g~", desc = "swap case" },
    { mode = "n", keys = "gJ", desc = "join (no space)" },
    { mode = "n", keys = "gq", desc = "format" },
    { mode = "n", keys = "gx", desc = "open under cursor" },
    { mode = "x", keys = "gu", desc = "lowercase" },
    { mode = "x", keys = "gU", desc = "uppercase" },
    { mode = "x", keys = "g~", desc = "swap case" },
    { mode = "x", keys = "gq", desc = "format" },
}
