local M = {}

--[[
  Base36 semantic palette — 15 neutrals + 15 pastel accents + 6 tinted bgs = 36 slots.

  Neutral band (dark → bright):
    bg_dark, bg, bg_panel, bg_alt, bg_cursor, bg_float,
    surface, line, overlay, muted, fg_dim, subtle, fg, fg_alt, bright

  The 6 neutral extensions fill the dark and mid zones so distinct
  UI layers (inactive splits, panels, cursorline, floats, separators,
  inactive text) each have their own dedicated shade.

  Pastel core (9):  red orange yellow green teal sky blue lavender pink
  Vivid extensions (6):  flame amber lime cyan indigo mauve

  The vivid layer provides a brighter, more saturated counterpart for each
  hue family so highlights can distinguish "the thing" from "the built-in
  variant of the thing" without relying on italic alone.

  Tinted backgrounds (6):  bg_red bg_amber bg_green bg_teal bg_blue bg_purple
  Dark hue-tinted bgs anchored to the editor bg. One per hue family, generic
  enough to serve diff, diagnostics, decorations, and similar colored-bg needs.
]]


local _default_palette = {
    -- neutrals (dark → bright)
    bg_dark  = '#26272B',   -- inactive splits, deepest bg layer
    bg       = '#2e2f33',   -- editor background
    bg_panel = '#34353a',   -- panels, sidebars, tabline
    bg_alt   = '#3a3b40',   -- general alternate bg (selection sbar, etc.)
    bg_cursor= '#3e3f46',   -- cursorline, colorcolumn
    bg_float = '#46474f',   -- floating windows, popups
    surface  = '#505157',   -- selection, visual highlight
    line     = '#585963',   -- separator lines (stronger than overlay)
    overlay  = '#6e6f77',   -- borders, gutter separators
    muted    = '#a0a2ad',   -- comments, deemphasised text
    fg_dim   = '#b4b5c0',   -- inactive UI text (winbar, statusline NC)
    subtle   = '#dcdce4',   -- line numbers, subtle UI
    fg       = '#f2f2f5',   -- primary foreground
    fg_alt   = '#fafafd',   -- bright foreground (titles, panels)
    bright   = '#f5f6fb',   -- maximum brightness / soft white

    -- pastel core
    red      = '#eebbbb',   -- errors, exceptions, delete
    orange   = '#eec8a2',   -- constants, numbers, branches
    yellow   = '#eee0ae',   -- types, warnings, labels, storage
    green    = '#b8dab8',   -- strings, success, additions
    teal     = '#a2d4d0',   -- special chars, regex, hints
    sky      = '#b2d6e6',   -- identifiers, properties, info
    blue     = '#acc4e6',   -- functions, directories, includes
    lavender = '#c8baec',   -- keywords, operators, conditionals
    pink     = '#e8bcd4',   -- delimiters, punctuation

    -- vivid extensions
    flame    = '#e89090',   -- macros, func-macros, critical errors
    amber    = '#dcb87e',   -- attributes, annotations, warnings-vivid
    lime     = '#c4de94',   -- constructors, enum members, gutter-add
    cyan     = '#8cd6de',   -- builtins (func/const/var), special funcs
    indigo   = '#98a8dc',   -- namespaces, modules, import, type-builtins
    mauve    = '#caaad0',   -- operators, punctuation-special, markup-em

    -- tinted backgrounds
    bg_red    = '#3b2d2d',   -- red-tinted bg   (errors, deletions, danger)
    bg_amber  = '#3E3A33',   -- amber-tinted bg  (warnings, changes)
    bg_green  = '#2d3830',   -- green-tinted bg  (success, additions)
    bg_teal   = '#2b3836',   -- teal-tinted bg   (hints, intra-line diffs)
    bg_blue   = '#2d3140',   -- blue-tinted bg   (info, selections)
    bg_purple = '#35303e',   -- purple-tinted bg (misc decorations)
}

local function _hl(group, opts)
    if type(opts) == 'string' then
        vim.api.nvim_set_hl(0, group, { link = opts })
        return
    end
    local val = {}
    if opts.fg  then val.fg = opts.fg end
    if opts.bg  then val.bg = opts.bg end
    if opts.sp  then val.sp = opts.sp end
    if opts.gui then
        for x in opts.gui:gmatch('([^,]+)') do
            if x ~= 'none' then val[x] = true end
        end
    end
    vim.api.nvim_set_hl(0, group, val)
end

function M.with_config(config)
    M.config = vim.tbl_extend('force',
        { notify = true, lsp_semantic = true, diffview = true, which_key = true },
        config or M.config or {})
end

function M.setup(config)
    M.with_config(config)

    if vim.fn.exists('syntax_on') then vim.cmd('syntax reset') end

    M.colors = (config.palette and next(config.palette) ~= nil)
        and vim.tbl_extend('force', _default_palette, config.palette)
        or _default_palette

    local c = M.colors

    -- ── Core ──────────────────────────────────────────────────────────
    _hl('Normal',        { fg = c.fg,      bg = c.bg })
    _hl('NormalNC',      { fg = c.fg,      bg = c.bg })
    _hl('NormalFloat',   { fg = c.fg,      bg = c.bg_float })
    _hl('FloatBorder',   { fg = c.overlay, bg = c.bg_float })
    _hl('FloatTitle',    { fg = c.blue,    bg = c.bg_float, gui = 'bold' })

    _hl('Bold',          { gui = 'bold' })
    _hl('Italic',        { gui = 'italic' })
    _hl('Underlined',    { fg = c.sky,     gui = 'underline' })

    -- ── Cursor & selection ────────────────────────────────────────────
    _hl('Cursor',        { fg = c.bg,      bg = c.fg })
    _hl('TermCursor',    { fg = c.bg,      bg = c.fg })
    _hl('TermCursorNC',  { fg = c.bg,      bg = c.muted })
    _hl('Visual',        { bg = c.surface })
    _hl('VisualNOS',     { bg = c.surface })
    _hl('MatchParen',    { bg = c.overlay, gui = 'bold' })
    _hl('SnippetTabstop',{ bg = c.bg_alt, sp = c.teal, gui = 'undercurl' })

    -- ── Search ────────────────────────────────────────────────────────
    _hl('Search',        { fg = c.bg,      bg = c.yellow })
    _hl('IncSearch',     { fg = c.bg,      bg = c.amber,  gui = 'bold' })
    _hl('Substitute',    { fg = c.bg,      bg = c.orange })
    _hl('CurSearch',     { fg = c.bg,      bg = c.amber })

    -- ── UI chrome ─────────────────────────────────────────────────────
    _hl('StatusLine',    { fg = c.fg_dim,  bg = c.bg_float,  gui = 'none' })
    _hl('StatusLineNC',  { fg = c.muted,   bg = c.bg_float, gui = 'none' })
    _hl('WinBar',        { fg = c.fg_dim,  bg = c.bg_float, gui = 'none' })
    _hl('WinBarNC',      { fg = c.muted,   bg = c.bg_float, gui = 'none' })
    _hl('VertSplit',     { fg = c.line })
    _hl('WinSeparator',  { fg = c.line })
    _hl('TabLine',       { fg = c.muted,   bg = c.bg_panel, gui = 'none' })
    _hl('TabLineFill',   { fg = c.muted,   bg = c.bg_panel, gui = 'none' })
    _hl('TabLineSel',    { fg = c.lime,    bg = c.bg_panel, gui = 'bold' })
    _hl('Title',         { fg = c.blue,    gui = 'bold' })
    _hl('Directory',     { fg = c.cyan })

    _hl('ColorColumn',   { bg = c.bg_cursor })
    _hl('CursorColumn',  { bg = c.bg_cursor })
    _hl('CursorLine',    { bg = c.bg_cursor })
    _hl('CursorLineNr',  { fg = c.subtle,  bg = c.bg_cursor })
    _hl('LineNr',        { fg = c.muted,   bg = c.bg })
    _hl('SignColumn',    { fg = c.muted,   bg = c.bg })
    _hl('FoldColumn',    { fg = c.overlay, bg = c.bg })
    _hl('Folded',        { fg = c.fg_dim,  bg = c.bg_panel })
    _hl('QuickFixLine',  { bg = c.bg_cursor })
    _hl('NonText',       { fg = c.overlay })
    _hl('SpecialKey',    { fg = c.overlay })
    _hl('Conceal',       { fg = c.overlay })
    _hl('Whitespace',    { fg = c.overlay })

    -- ── Popup menu ────────────────────────────────────────────────────
    _hl('PMenu',         { fg = c.fg,      bg = c.bg_float })
    _hl('PMenuSel',      { fg = c.bg,      bg = c.blue })
    _hl('PMenuSbar',     { bg = c.bg_alt })
    _hl('PMenuThumb',    { bg = c.overlay })

    -- ── Messages ──────────────────────────────────────────────────────
    _hl('ModeMsg',       { fg = c.lime })
    _hl('MoreMsg',       { fg = c.green })
    _hl('Question',      { fg = c.sky })
    _hl('WarningMsg',    { fg = c.amber })
    _hl('ErrorMsg',      { fg = c.red,     bg = c.bg })
    _hl('Error',         { fg = c.red,     bg = c.bg })
    _hl('Debug',         { fg = c.flame })
    _hl('TooLong',       { fg = c.red })
    _hl('WildMenu',      { fg = c.bg,      bg = c.amber })

    -- ── Syntax ────────────────────────────────────────────────────────
    _hl('Comment',       { fg = c.muted,   gui = 'italic' })
    _hl('String',        { fg = c.green })
    _hl('Character',     { fg = c.green })
    _hl('Number',        { fg = c.orange })
    _hl('Float',         { fg = c.orange })
    _hl('Boolean',       { fg = c.orange })
    _hl('Constant',      { fg = c.orange })
    _hl('Identifier',    { fg = c.sky,     gui = 'none' })
    _hl('Function',      { fg = c.blue })
    _hl('Keyword',       { fg = c.lavender })
    _hl('Conditional',   { fg = c.lavender })
    _hl('Repeat',        { fg = c.lavender })
    _hl('Statement',     { fg = c.lavender })
    _hl('Operator',      { fg = c.mauve,   gui = 'none' })
    _hl('Exception',     { fg = c.red })
    _hl('Macro',         { fg = c.flame })
    _hl('PreProc',       { fg = c.indigo })
    _hl('Include',       { fg = c.indigo })
    _hl('Define',        { fg = c.lavender, gui = 'none' })
    _hl('Type',          { fg = c.yellow,  gui = 'none' })
    _hl('Typedef',       { fg = c.yellow })
    _hl('StorageClass',  { fg = c.yellow })
    _hl('Structure',     { fg = c.yellow })
    _hl('Special',       { fg = c.teal })
    _hl('SpecialChar',   { fg = c.cyan })
    _hl('Tag',           { fg = c.amber })
    _hl('Label',         { fg = c.yellow })
    _hl('Delimiter',     { fg = c.pink })
    _hl('Todo',          { fg = c.amber,   bg = c.bg_alt, gui = 'bold' })

    -- ── Diff ──────────────────────────────────────────────────────────
    _hl('DiffAdd',       { bg = c.bg_green  })
    _hl('DiffDelete',    { bg = c.bg_red    })
    _hl('DiffChange',    { bg = c.bg_amber  })
    _hl('DiffText',      { bg = c.bg_teal,  gui = 'bold' })
    _hl('DiffAdded',     { fg = c.green,       bg = c.bg })
    _hl('DiffRemoved',   { fg = c.red,         bg = c.bg })
    _hl('DiffFile',      { fg = c.flame,       bg = c.bg })
    _hl('DiffNewFile',   { fg = c.lime,        bg = c.bg })
    _hl('DiffLine',      { fg = c.indigo,      bg = c.bg })

    -- ── Git ───────────────────────────────────────────────────────────
    _hl('gitcommitSummary',        { fg = c.lime })
    _hl('gitcommitComment',        { fg = c.muted })
    _hl('gitcommitOverflow',       { fg = c.red })
    _hl('gitcommitUntracked',      { fg = c.muted })
    _hl('gitcommitDiscarded',      { fg = c.muted })
    _hl('gitcommitSelected',       { fg = c.muted })
    _hl('gitcommitHeader',         { fg = c.lavender })
    _hl('gitcommitSelectedType',   { fg = c.blue })
    _hl('gitcommitUnmergedType',   { fg = c.sky })
    _hl('gitcommitDiscardedType',  { fg = c.sky })
    _hl('gitcommitBranch',         { fg = c.amber,    gui = 'bold' })
    _hl('gitcommitUntrackedFile',  { fg = c.yellow })
    _hl('gitcommitUnmergedFile',   { fg = c.flame,    gui = 'bold' })
    _hl('gitcommitDiscardedFile',  { fg = c.red,      gui = 'bold' })
    _hl('gitcommitSelectedFile',   { fg = c.green,    gui = 'bold' })

    _hl('GitGutterAdd',            { fg = c.lime,     bg = c.bg })
    _hl('GitGutterChange',         { fg = c.amber,    bg = c.bg })
    _hl('GitGutterDelete',         { fg = c.red,      bg = c.bg })
    _hl('GitGutterChangeDelete',   { fg = c.mauve,    bg = c.bg })

    -- ── Spell ─────────────────────────────────────────────────────────
    _hl('SpellBad',      { gui = 'undercurl', sp = c.red })
    _hl('SpellLocal',    { gui = 'undercurl', sp = c.cyan })
    _hl('SpellCap',      { gui = 'undercurl', sp = c.blue })
    _hl('SpellRare',     { gui = 'undercurl', sp = c.mauve })

    -- ── Diagnostics ───────────────────────────────────────────────────
    _hl('DiagnosticError',               { fg = c.red })
    _hl('DiagnosticWarn',                { fg = c.amber })
    _hl('DiagnosticInfo',                { fg = c.sky })
    _hl('DiagnosticHint',                { fg = c.teal })
    _hl('DiagnosticOk',                  { fg = c.lime })
    _hl('DiagnosticUnderlineError',      { gui = 'undercurl', sp = c.red })
    _hl('DiagnosticUnderlineWarning',    { gui = 'undercurl', sp = c.amber })
    _hl('DiagnosticUnderlineWarn',       { gui = 'undercurl', sp = c.amber })
    _hl('DiagnosticUnderlineInformation',{ gui = 'undercurl', sp = c.sky })
    _hl('DiagnosticUnderlineHint',       { gui = 'undercurl', sp = c.teal })
    _hl('DiagnosticUnderlineOk',         { gui = 'undercurl', sp = c.lime })

    -- ── LSP ───────────────────────────────────────────────────────────
    _hl('LspReferenceText',           { gui = 'underline', sp = c.subtle })
    _hl('LspReferenceRead',           { gui = 'underline', sp = c.subtle })
    _hl('LspReferenceWrite',          { gui = 'underline', sp = c.amber })
    _hl('LspInlayHint',               { fg = c.muted,      gui = 'italic' })
    _hl('LspSignatureActiveParameter',{ fg = c.lavender,   gui = 'bold' })

    -- ── Treesitter (@-namespace, Neovim 0.9+) ─────────────────────────
    _hl('@variable',              { fg = c.fg })
    _hl('@variable.builtin',      { fg = c.cyan,     gui = 'italic' })
    _hl('@variable.parameter',    { fg = c.fg })
    _hl('@variable.member',       { fg = c.sky })

    _hl('@string',                { fg = c.green })
    _hl('@string.escape',         { fg = c.cyan })
    _hl('@string.regex',          { fg = c.teal })
    _hl('@string.special',        { fg = c.cyan })

    _hl('@number',                { fg = c.orange })
    _hl('@number.float',          { fg = c.orange })
    _hl('@boolean',               { fg = c.orange })

    _hl('@constant',              { fg = c.orange })
    _hl('@constant.builtin',      { fg = c.cyan,     gui = 'italic' })
    _hl('@constant.macro',        { fg = c.flame })

    _hl('@function',              { fg = c.blue })
    _hl('@function.builtin',      { fg = c.cyan,     gui = 'italic' })
    _hl('@function.macro',        { fg = c.flame })
    _hl('@function.method',       { fg = c.sky })
    _hl('@function.call',         { fg = c.blue })
    _hl('@function.method.call',  { fg = c.sky })

    _hl('@constructor',           { fg = c.lime })

    _hl('@keyword',               { fg = c.lavender })
    _hl('@keyword.function',      { fg = c.lavender })
    _hl('@keyword.operator',      { fg = c.mauve })
    _hl('@keyword.return',        { fg = c.lavender })
    _hl('@keyword.import',        { fg = c.indigo })
    _hl('@keyword.conditional',   { fg = c.lavender })
    _hl('@keyword.repeat',        { fg = c.lavender })
    _hl('@keyword.exception',     { fg = c.red })

    _hl('@type',                  { fg = c.yellow })
    _hl('@type.builtin',          { fg = c.indigo,   gui = 'italic' })
    _hl('@type.definition',       { fg = c.yellow })

    _hl('@attribute',             { fg = c.amber })
    _hl('@annotation',            { fg = c.mauve })

    _hl('@namespace',             { fg = c.indigo })
    _hl('@module',                { fg = c.indigo })
    _hl('@module.builtin',        { fg = c.indigo,   gui = 'italic' })

    _hl('@operator',              { fg = c.mauve })
    _hl('@punctuation.delimiter', { fg = c.pink })
    _hl('@punctuation.bracket',   { fg = c.subtle })
    _hl('@punctuation.special',   { fg = c.mauve })

    _hl('@comment',               { fg = c.muted,    gui = 'italic' })
    _hl('@comment.documentation', { fg = c.subtle,   gui = 'italic' })
    _hl('@comment.error',         { fg = c.red,      gui = 'bold' })
    _hl('@comment.warning',       { fg = c.amber,    gui = 'bold' })
    _hl('@comment.todo',          { fg = c.amber,    gui = 'bold' })
    _hl('@comment.note',          { fg = c.sky,      gui = 'bold' })

    _hl('@tag',                   { fg = c.amber })
    _hl('@tag.delimiter',         { fg = c.pink })
    _hl('@tag.attribute',         { fg = c.sky })

    _hl('@property',              { fg = c.sky })

    -- @text.* (Neovim < 0.10 tree-sitter text nodes)
    _hl('@text.strong',           { gui = 'bold' })
    _hl('@text.emphasis',         { fg = c.mauve,    gui = 'italic' })
    _hl('@text.underline',        { gui = 'underline' })
    _hl('@text.strike',           { gui = 'strikethrough' })
    _hl('@text.title',            { fg = c.blue,     gui = 'bold' })
    _hl('@text.literal',          { fg = c.teal })
    _hl('@text.uri',              { fg = c.sky,      gui = 'underline' })
    _hl('@text.reference',        { fg = c.lavender })
    _hl('@text.todo',             { fg = c.amber,    bg = c.bg_alt, gui = 'bold' })
    _hl('@text.warning',          { fg = c.amber })
    _hl('@text.danger',           { fg = c.red })
    _hl('@text.note',             { fg = c.sky })

    -- @markup.* (Neovim 0.10+)
    _hl('@markup.strong',         { gui = 'bold' })
    _hl('@markup.italic',         { gui = 'italic' })
    _hl('@markup.underline',      { gui = 'underline' })
    _hl('@markup.strikethrough',  { gui = 'strikethrough' })
    _hl('@markup.heading',        { fg = c.blue,     gui = 'bold' })
    _hl('@markup.heading.1',      { fg = c.blue,     gui = 'bold' })
    _hl('@markup.heading.2',      { fg = c.indigo,   gui = 'bold' })
    _hl('@markup.heading.3',      { fg = c.lavender, gui = 'bold' })
    _hl('@markup.heading.4',      { fg = c.sky,      gui = 'bold' })
    _hl('@markup.raw',            { fg = c.teal })
    _hl('@markup.raw.block',      { fg = c.teal })
    _hl('@markup.link',           { fg = c.sky,      gui = 'underline' })
    _hl('@markup.link.label',     { fg = c.lavender })
    _hl('@markup.link.url',       { fg = c.sky,      gui = 'underline' })
    _hl('@markup.list',           { fg = c.pink })
    _hl('@markup.list.checked',   { fg = c.lime })
    _hl('@markup.list.unchecked', { fg = c.subtle })
    _hl('@markup.quote',          { fg = c.muted,    gui = 'italic' })
    _hl('@markup.math',           { fg = c.cyan })

    _hl('NvimInternalError',      { fg = c.bg,  bg = c.flame })

    -- ── Diffview ──────────────────────────────────────────────────────
    if M.config.diffview then
        _hl('DiffviewNormal',              { fg = c.fg,      bg = c.bg })
        _hl('DiffviewCursorLine',          { bg = c.bg_cursor })
        _hl('DiffviewSignColumn',          { fg = c.subtle,  bg = c.bg })
        _hl('DiffviewEndOfBuffer',         { fg = c.muted })
        _hl('DiffviewLineNr',              { fg = c.subtle })
        _hl('DiffviewWinSeparator',        { fg = c.overlay })
        _hl('DiffviewFilePanelTitle',      { fg = c.fg_alt,  gui = 'bold' })
        _hl('DiffviewFilePanelCounter',    { fg = c.subtle })
        _hl('DiffviewFilePanelFileName',   { fg = c.fg_alt })
        _hl('DiffviewFilePanelPath',       { fg = c.subtle })
        _hl('DiffviewFilePanelRootPath',   { fg = c.fg_alt,  gui = 'bold' })
        _hl('DiffviewFilePanelInsertions', { fg = c.lime,    gui = 'bold' })
        _hl('DiffviewFilePanelDeletions',  { fg = c.red,     gui = 'bold' })
        _hl('DiffviewStatusAdded',         { fg = c.lime,    gui = 'bold' })
        _hl('DiffviewStatusUntracked',     { fg = c.lime })
        _hl('DiffviewStatusModified',      { fg = c.amber,   gui = 'bold' })
        _hl('DiffviewStatusRenamed',       { fg = c.sky,     gui = 'bold' })
        _hl('DiffviewStatusCopied',        { fg = c.sky })
        _hl('DiffviewStatusTypeChange',    { fg = c.mauve,   gui = 'bold' })
        _hl('DiffviewStatusDeleted',       { fg = c.red,     gui = 'bold' })
        _hl('DiffviewStatusBroken',        { fg = c.flame,   gui = 'bold' })
        _hl('DiffviewStatusUnknown',       { fg = c.red })
        _hl('DiffviewStatusUnmerged',      { fg = c.lavender, gui = 'bold' })
        _hl('DiffviewDiffAddAsDelete',     { fg = c.flame,   bg = c.bg_red })
        _hl('DiffviewDiffDelete',          { fg = c.muted,   bg = c.bg })
    end

    -- ── Which-key ─────────────────────────────────────────────────────
    if M.config.which_key then
        _hl('WhichKey',          { fg = c.cyan })
        _hl('WhichKeyDesc',      { fg = c.fg })
        _hl('WhichKeyFloat',     { fg = c.fg,      bg = c.bg_float })
        _hl('WhichKeyGroup',     { fg = c.indigo })
        _hl('WhichKeySeparator', { fg = c.lime })
        _hl('WhichKeyValue',     { fg = c.muted })
    end


    -- ── Terminal colors ───────────────────────────────────────────────
    -- normal:  0=black  1=red    2=green  3=yellow  4=blue  5=magenta  6=cyan  7=white
    -- bright:  8=       9=       10=      11=        12=     13=        14=     15=
    vim.g.terminal_color_0  = c.bg
    vim.g.terminal_color_1  = c.red
    vim.g.terminal_color_2  = c.green
    vim.g.terminal_color_3  = c.yellow
    vim.g.terminal_color_4  = c.blue
    vim.g.terminal_color_5  = c.lavender
    vim.g.terminal_color_6  = c.teal
    vim.g.terminal_color_7  = c.fg
    vim.g.terminal_color_8  = c.muted
    vim.g.terminal_color_9  = c.flame
    vim.g.terminal_color_10 = c.lime
    vim.g.terminal_color_11 = c.amber
    vim.g.terminal_color_12 = c.indigo
    vim.g.terminal_color_13 = c.mauve
    vim.g.terminal_color_14 = c.cyan
    vim.g.terminal_color_15 = c.bright
end

return M
