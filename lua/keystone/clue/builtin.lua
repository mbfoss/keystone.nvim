--- Built-in (non-mapped) key sequences worth hinting. These are *virtual* clue
--- entries: `keystone.clue` never executes them — Neovim runs the built-in as
--- usual — they exist only so the clue window has something to show for prefixes
--- like `<C-w>`, `z`, `g` and the operator/text-object family (`ciw`, `da"`,
--- `vi(` …) that are not backed by user mappings.
---@type keystone.clue.Clue[]
local _clues = {
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

-- Text objects: the key that selects an object once an `i`/`a` selector has been
-- pressed, paired with a readable name. Several keys map to the same object
-- (`b`/`(`/`)`, `B`/`{`/`}`, …) — Neovim accepts any of them.
---@type [string, string][]
local _textobjects = {
    { "w", "word" },
    { "W", "WORD" },
    { "s", "sentence" },
    { "p", "paragraph" },
    { "(", "parens" },
    { ")", "parens" },
    { "b", "parens" },
    { "{", "braces" },
    { "}", "braces" },
    { "B", "braces" },
    { "[", "brackets" },
    { "]", "brackets" },
    { "<", "angle" },
    { ">", "angle" },
    { "t", "tag" },
    { '"', "double quotes" },
    { "'", "single quotes" },
    { "`", "backticks" },
}

-- Normal-mode operators that accept a text object, e.g. `c` in `ciw`. `v`
-- (Visual) is deliberately omitted as a prefix: it enters a mode rather than
-- pending on the next key, so we hint text objects from the Visual-mode `i`/`a`
-- selectors instead (see the `x` pass below), and avoid intercepting it.
local _operators = { "c", "d", "y" }

--- Append `<prefix>i<obj>` / `<prefix>a<obj>` clues for every text object.
---@param mode string
---@param prefix string operator keys preceding the selector (empty in Visual)
local function _emit(mode, prefix)
    for _, sel in ipairs({ "i", "a" }) do
        for _, obj in ipairs(_textobjects) do
            table.insert(_clues, { mode = mode, keys = prefix .. sel .. obj[1], desc = obj[2] })
        end
    end
end

for _, op in ipairs(_operators) do
    _emit("n", op)
end
-- Visual mode: an object is selected directly with `i`/`a` (already selecting),
-- which also covers the `vi…`/`va…`/`Vi…` flows once Visual mode is entered.
_emit("x", "")

return _clues
