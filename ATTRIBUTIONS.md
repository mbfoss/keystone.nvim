# Attributions

This project uses or is based on the following third-party projects:

## Bundled data

- **[Nerd Fonts](https://github.com/ryanoasis/nerd-fonts)** (MIT) — the icon
  glyphs in `lua/keystone/icon/data.lua` are Nerd Fonts codepoints. No font file
  is bundled or redistributed; the data table only references codepoints, which
  the user's own patched font renders.
- **[Catppuccin](https://github.com/catppuccin/catppuccin)** (MIT) — the colour
  values paired with those icons follow the Catppuccin Mocha palette.

The icon table itself — the filetype list, the extension and filename maps, and
the glyph/colour pairing — was compiled for this plugin. It is not derived from
the data files of `nvim-web-devicons`, `mini.icons` or any other icon plugin.

## Runtime integrations (not bundled)

Modules are detected at runtime and used only if the user has installed them;
none of their code is vendored here. Where a keystone module covers the same
ground as a well-known plugin (`clue` and which-key, `animate`, `notify`,
`statusline`, `filetree`), the implementation was written for this plugin from
Neovim's public API rather than adapted from that plugin's source.

## Development-time only (not distributed)

- **[panvimdoc](https://github.com/kdheepak/panvimdoc)** (MIT) — generates
  `doc/keystone*.txt` from the Markdown docs; see `scripts/gendoc.sh`.
- **[busted](https://github.com/lunarmodules/busted)** and
  **[luassert](https://github.com/lunarmodules/luassert)** (MIT), and
  **[nlua](https://github.com/mfussenegger/nlua)** (GPL-3.0) — the test
  toolchain. These are installed locally by the developer and invoked as
  separate programs; no part of them is linked into or shipped with this plugin.
