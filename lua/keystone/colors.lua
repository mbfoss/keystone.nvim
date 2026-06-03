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


local default_palette = {
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

local function hl(group, opts)
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
        and vim.tbl_extend('force', default_palette, config.palette)
        or default_palette

    local c = M.colors

    -- ── Core ──────────────────────────────────────────────────────────
    hl('Normal',        { fg = c.fg,      bg = c.bg })
    hl('NormalNC',      { fg = c.fg,      bg = c.bg })
    hl('NormalFloat',   { fg = c.fg,      bg = c.bg_float })
    hl('FloatBorder',   { fg = c.overlay, bg = c.bg_float })
    hl('FloatTitle',    { fg = c.blue,    bg = c.bg_float, gui = 'bold' })

    hl('Bold',          { gui = 'bold' })
    hl('Italic',        { gui = 'italic' })
    hl('Underlined',    { fg = c.sky,     gui = 'underline' })

    -- ── Cursor & selection ────────────────────────────────────────────
    hl('Cursor',        { fg = c.bg,      bg = c.fg })
    hl('TermCursor',    { fg = c.bg,      bg = c.fg })
    hl('TermCursorNC',  { fg = c.bg,      bg = c.muted })
    hl('Visual',        { bg = c.surface })
    hl('VisualNOS',     { bg = c.surface })
    hl('MatchParen',    { bg = c.overlay, gui = 'bold' })
    hl('SnippetTabstop',{ bg = c.bg_alt, sp = c.teal, gui = 'undercurl' })

    -- ── Search ────────────────────────────────────────────────────────
    hl('Search',        { fg = c.bg,      bg = c.yellow })
    hl('IncSearch',     { fg = c.bg,      bg = c.amber,  gui = 'bold' })
    hl('Substitute',    { fg = c.bg,      bg = c.orange })
    hl('CurSearch',     { fg = c.bg,      bg = c.amber })

    -- ── UI chrome ─────────────────────────────────────────────────────
    hl('StatusLine',    { fg = c.fg_dim,  bg = c.bg_float,  gui = 'none' })
    hl('StatusLineNC',  { fg = c.muted,   bg = c.bg_float, gui = 'none' })
    hl('WinBar',        { fg = c.fg_dim,  bg = c.bg_float, gui = 'none' })
    hl('WinBarNC',      { fg = c.muted,   bg = c.bg_float, gui = 'none' })
    hl('VertSplit',     { fg = c.line })
    hl('WinSeparator',  { fg = c.line })
    hl('TabLine',       { fg = c.muted,   bg = c.bg_panel, gui = 'none' })
    hl('TabLineFill',   { fg = c.muted,   bg = c.bg_panel, gui = 'none' })
    hl('TabLineSel',    { fg = c.lime,    bg = c.bg_panel, gui = 'bold' })
    hl('Title',         { fg = c.blue,    gui = 'bold' })
    hl('Directory',     { fg = c.cyan })

    hl('ColorColumn',   { bg = c.bg_cursor })
    hl('CursorColumn',  { bg = c.bg_cursor })
    hl('CursorLine',    { bg = c.bg_cursor })
    hl('CursorLineNr',  { fg = c.subtle,  bg = c.bg_cursor })
    hl('LineNr',        { fg = c.muted,   bg = c.bg })
    hl('SignColumn',    { fg = c.muted,   bg = c.bg })
    hl('FoldColumn',    { fg = c.overlay, bg = c.bg })
    hl('Folded',        { fg = c.fg_dim,  bg = c.bg_panel })
    hl('QuickFixLine',  { bg = c.bg_cursor })
    hl('NonText',       { fg = c.overlay })
    hl('SpecialKey',    { fg = c.overlay })
    hl('Conceal',       { fg = c.overlay })
    hl('Whitespace',    { fg = c.overlay })

    -- ── Popup menu ────────────────────────────────────────────────────
    hl('PMenu',         { fg = c.fg,      bg = c.bg_float })
    hl('PMenuSel',      { fg = c.bg,      bg = c.blue })
    hl('PMenuSbar',     { bg = c.bg_alt })
    hl('PMenuThumb',    { bg = c.overlay })

    -- ── Messages ──────────────────────────────────────────────────────
    hl('ModeMsg',       { fg = c.lime })
    hl('MoreMsg',       { fg = c.green })
    hl('Question',      { fg = c.sky })
    hl('WarningMsg',    { fg = c.amber })
    hl('ErrorMsg',      { fg = c.red,     bg = c.bg })
    hl('Error',         { fg = c.red,     bg = c.bg })
    hl('Debug',         { fg = c.flame })
    hl('TooLong',       { fg = c.red })
    hl('WildMenu',      { fg = c.bg,      bg = c.amber })

    -- ── Syntax ────────────────────────────────────────────────────────
    hl('Comment',       { fg = c.muted,   gui = 'italic' })
    hl('String',        { fg = c.green })
    hl('Character',     { fg = c.green })
    hl('Number',        { fg = c.orange })
    hl('Float',         { fg = c.orange })
    hl('Boolean',       { fg = c.orange })
    hl('Constant',      { fg = c.orange })
    hl('Identifier',    { fg = c.sky,     gui = 'none' })
    hl('Function',      { fg = c.blue })
    hl('Keyword',       { fg = c.lavender })
    hl('Conditional',   { fg = c.lavender })
    hl('Repeat',        { fg = c.lavender })
    hl('Statement',     { fg = c.lavender })
    hl('Operator',      { fg = c.mauve,   gui = 'none' })
    hl('Exception',     { fg = c.red })
    hl('Macro',         { fg = c.flame })
    hl('PreProc',       { fg = c.indigo })
    hl('Include',       { fg = c.indigo })
    hl('Define',        { fg = c.lavender, gui = 'none' })
    hl('Type',          { fg = c.yellow,  gui = 'none' })
    hl('Typedef',       { fg = c.yellow })
    hl('StorageClass',  { fg = c.yellow })
    hl('Structure',     { fg = c.yellow })
    hl('Special',       { fg = c.teal })
    hl('SpecialChar',   { fg = c.cyan })
    hl('Tag',           { fg = c.amber })
    hl('Label',         { fg = c.yellow })
    hl('Delimiter',     { fg = c.pink })
    hl('Todo',          { fg = c.amber,   bg = c.bg_alt, gui = 'bold' })

    -- ── Diff ──────────────────────────────────────────────────────────
    hl('DiffAdd',       { bg = c.bg_green  })
    hl('DiffDelete',    { bg = c.bg_red    })
    hl('DiffChange',    { bg = c.bg_amber  })
    hl('DiffText',      { bg = c.bg_teal,  gui = 'bold' })
    hl('DiffAdded',     { fg = c.green,       bg = c.bg })
    hl('DiffRemoved',   { fg = c.red,         bg = c.bg })
    hl('DiffFile',      { fg = c.flame,       bg = c.bg })
    hl('DiffNewFile',   { fg = c.lime,        bg = c.bg })
    hl('DiffLine',      { fg = c.indigo,      bg = c.bg })

    -- ── Git ───────────────────────────────────────────────────────────
    hl('gitcommitSummary',        { fg = c.lime })
    hl('gitcommitComment',        { fg = c.muted })
    hl('gitcommitOverflow',       { fg = c.red })
    hl('gitcommitUntracked',      { fg = c.muted })
    hl('gitcommitDiscarded',      { fg = c.muted })
    hl('gitcommitSelected',       { fg = c.muted })
    hl('gitcommitHeader',         { fg = c.lavender })
    hl('gitcommitSelectedType',   { fg = c.blue })
    hl('gitcommitUnmergedType',   { fg = c.sky })
    hl('gitcommitDiscardedType',  { fg = c.sky })
    hl('gitcommitBranch',         { fg = c.amber,    gui = 'bold' })
    hl('gitcommitUntrackedFile',  { fg = c.yellow })
    hl('gitcommitUnmergedFile',   { fg = c.flame,    gui = 'bold' })
    hl('gitcommitDiscardedFile',  { fg = c.red,      gui = 'bold' })
    hl('gitcommitSelectedFile',   { fg = c.green,    gui = 'bold' })

    hl('GitGutterAdd',            { fg = c.lime,     bg = c.bg })
    hl('GitGutterChange',         { fg = c.amber,    bg = c.bg })
    hl('GitGutterDelete',         { fg = c.red,      bg = c.bg })
    hl('GitGutterChangeDelete',   { fg = c.mauve,    bg = c.bg })

    -- ── Spell ─────────────────────────────────────────────────────────
    hl('SpellBad',      { gui = 'undercurl', sp = c.red })
    hl('SpellLocal',    { gui = 'undercurl', sp = c.cyan })
    hl('SpellCap',      { gui = 'undercurl', sp = c.blue })
    hl('SpellRare',     { gui = 'undercurl', sp = c.mauve })

    -- ── Diagnostics ───────────────────────────────────────────────────
    hl('DiagnosticError',               { fg = c.red })
    hl('DiagnosticWarn',                { fg = c.amber })
    hl('DiagnosticInfo',                { fg = c.sky })
    hl('DiagnosticHint',                { fg = c.teal })
    hl('DiagnosticOk',                  { fg = c.lime })
    hl('DiagnosticUnderlineError',      { gui = 'undercurl', sp = c.red })
    hl('DiagnosticUnderlineWarning',    { gui = 'undercurl', sp = c.amber })
    hl('DiagnosticUnderlineWarn',       { gui = 'undercurl', sp = c.amber })
    hl('DiagnosticUnderlineInformation',{ gui = 'undercurl', sp = c.sky })
    hl('DiagnosticUnderlineHint',       { gui = 'undercurl', sp = c.teal })
    hl('DiagnosticUnderlineOk',         { gui = 'undercurl', sp = c.lime })

    -- ── LSP ───────────────────────────────────────────────────────────
    hl('LspReferenceText',           { gui = 'underline', sp = c.subtle })
    hl('LspReferenceRead',           { gui = 'underline', sp = c.subtle })
    hl('LspReferenceWrite',          { gui = 'underline', sp = c.amber })
    hl('LspInlayHint',               { fg = c.muted,      gui = 'italic' })
    hl('LspSignatureActiveParameter',{ fg = c.lavender,   gui = 'bold' })

    -- ── Treesitter (@-namespace, Neovim 0.9+) ─────────────────────────
    hl('@variable',              { fg = c.fg })
    hl('@variable.builtin',      { fg = c.cyan,     gui = 'italic' })
    hl('@variable.parameter',    { fg = c.fg })
    hl('@variable.member',       { fg = c.sky })

    hl('@string',                { fg = c.green })
    hl('@string.escape',         { fg = c.cyan })
    hl('@string.regex',          { fg = c.teal })
    hl('@string.special',        { fg = c.cyan })

    hl('@number',                { fg = c.orange })
    hl('@number.float',          { fg = c.orange })
    hl('@boolean',               { fg = c.orange })

    hl('@constant',              { fg = c.orange })
    hl('@constant.builtin',      { fg = c.cyan,     gui = 'italic' })
    hl('@constant.macro',        { fg = c.flame })

    hl('@function',              { fg = c.blue })
    hl('@function.builtin',      { fg = c.cyan,     gui = 'italic' })
    hl('@function.macro',        { fg = c.flame })
    hl('@function.method',       { fg = c.sky })
    hl('@function.call',         { fg = c.blue })
    hl('@function.method.call',  { fg = c.sky })

    hl('@constructor',           { fg = c.lime })

    hl('@keyword',               { fg = c.lavender })
    hl('@keyword.function',      { fg = c.lavender })
    hl('@keyword.operator',      { fg = c.mauve })
    hl('@keyword.return',        { fg = c.lavender })
    hl('@keyword.import',        { fg = c.indigo })
    hl('@keyword.conditional',   { fg = c.lavender })
    hl('@keyword.repeat',        { fg = c.lavender })
    hl('@keyword.exception',     { fg = c.red })

    hl('@type',                  { fg = c.yellow })
    hl('@type.builtin',          { fg = c.indigo,   gui = 'italic' })
    hl('@type.definition',       { fg = c.yellow })

    hl('@attribute',             { fg = c.amber })
    hl('@annotation',            { fg = c.mauve })

    hl('@namespace',             { fg = c.indigo })
    hl('@module',                { fg = c.indigo })
    hl('@module.builtin',        { fg = c.indigo,   gui = 'italic' })

    hl('@operator',              { fg = c.mauve })
    hl('@punctuation.delimiter', { fg = c.pink })
    hl('@punctuation.bracket',   { fg = c.subtle })
    hl('@punctuation.special',   { fg = c.mauve })

    hl('@comment',               { fg = c.muted,    gui = 'italic' })
    hl('@comment.documentation', { fg = c.subtle,   gui = 'italic' })
    hl('@comment.error',         { fg = c.red,      gui = 'bold' })
    hl('@comment.warning',       { fg = c.amber,    gui = 'bold' })
    hl('@comment.todo',          { fg = c.amber,    gui = 'bold' })
    hl('@comment.note',          { fg = c.sky,      gui = 'bold' })

    hl('@tag',                   { fg = c.amber })
    hl('@tag.delimiter',         { fg = c.pink })
    hl('@tag.attribute',         { fg = c.sky })

    hl('@property',              { fg = c.sky })

    -- @text.* (Neovim < 0.10 tree-sitter text nodes)
    hl('@text.strong',           { gui = 'bold' })
    hl('@text.emphasis',         { fg = c.mauve,    gui = 'italic' })
    hl('@text.underline',        { gui = 'underline' })
    hl('@text.strike',           { gui = 'strikethrough' })
    hl('@text.title',            { fg = c.blue,     gui = 'bold' })
    hl('@text.literal',          { fg = c.teal })
    hl('@text.uri',              { fg = c.sky,      gui = 'underline' })
    hl('@text.reference',        { fg = c.lavender })
    hl('@text.todo',             { fg = c.amber,    bg = c.bg_alt, gui = 'bold' })
    hl('@text.warning',          { fg = c.amber })
    hl('@text.danger',           { fg = c.red })
    hl('@text.note',             { fg = c.sky })

    -- @markup.* (Neovim 0.10+)
    hl('@markup.strong',         { gui = 'bold' })
    hl('@markup.italic',         { gui = 'italic' })
    hl('@markup.underline',      { gui = 'underline' })
    hl('@markup.strikethrough',  { gui = 'strikethrough' })
    hl('@markup.heading',        { fg = c.blue,     gui = 'bold' })
    hl('@markup.heading.1',      { fg = c.blue,     gui = 'bold' })
    hl('@markup.heading.2',      { fg = c.indigo,   gui = 'bold' })
    hl('@markup.heading.3',      { fg = c.lavender, gui = 'bold' })
    hl('@markup.heading.4',      { fg = c.sky,      gui = 'bold' })
    hl('@markup.raw',            { fg = c.teal })
    hl('@markup.raw.block',      { fg = c.teal })
    hl('@markup.link',           { fg = c.sky,      gui = 'underline' })
    hl('@markup.link.label',     { fg = c.lavender })
    hl('@markup.link.url',       { fg = c.sky,      gui = 'underline' })
    hl('@markup.list',           { fg = c.pink })
    hl('@markup.list.checked',   { fg = c.lime })
    hl('@markup.list.unchecked', { fg = c.subtle })
    hl('@markup.quote',          { fg = c.muted,    gui = 'italic' })
    hl('@markup.math',           { fg = c.cyan })

    hl('NvimInternalError',      { fg = c.bg,  bg = c.flame })

    -- ── Diffview ──────────────────────────────────────────────────────
    if M.config.diffview then
        hl('DiffviewNormal',              { fg = c.fg,      bg = c.bg })
        hl('DiffviewCursorLine',          { bg = c.bg_cursor })
        hl('DiffviewSignColumn',          { fg = c.subtle,  bg = c.bg })
        hl('DiffviewEndOfBuffer',         { fg = c.muted })
        hl('DiffviewLineNr',              { fg = c.subtle })
        hl('DiffviewWinSeparator',        { fg = c.overlay })
        hl('DiffviewFilePanelTitle',      { fg = c.fg_alt,  gui = 'bold' })
        hl('DiffviewFilePanelCounter',    { fg = c.subtle })
        hl('DiffviewFilePanelFileName',   { fg = c.fg_alt })
        hl('DiffviewFilePanelPath',       { fg = c.subtle })
        hl('DiffviewFilePanelRootPath',   { fg = c.fg_alt,  gui = 'bold' })
        hl('DiffviewFilePanelInsertions', { fg = c.lime,    gui = 'bold' })
        hl('DiffviewFilePanelDeletions',  { fg = c.red,     gui = 'bold' })
        hl('DiffviewStatusAdded',         { fg = c.lime,    gui = 'bold' })
        hl('DiffviewStatusUntracked',     { fg = c.lime })
        hl('DiffviewStatusModified',      { fg = c.amber,   gui = 'bold' })
        hl('DiffviewStatusRenamed',       { fg = c.sky,     gui = 'bold' })
        hl('DiffviewStatusCopied',        { fg = c.sky })
        hl('DiffviewStatusTypeChange',    { fg = c.mauve,   gui = 'bold' })
        hl('DiffviewStatusDeleted',       { fg = c.red,     gui = 'bold' })
        hl('DiffviewStatusBroken',        { fg = c.flame,   gui = 'bold' })
        hl('DiffviewStatusUnknown',       { fg = c.red })
        hl('DiffviewStatusUnmerged',      { fg = c.lavender, gui = 'bold' })
        hl('DiffviewDiffAddAsDelete',     { fg = c.flame,   bg = c.bg_red })
        hl('DiffviewDiffDelete',          { fg = c.muted,   bg = c.bg })
    end

    -- ── Which-key ─────────────────────────────────────────────────────
    if M.config.which_key then
        hl('WhichKey',          { fg = c.cyan })
        hl('WhichKeyDesc',      { fg = c.fg })
        hl('WhichKeyFloat',     { fg = c.fg,      bg = c.bg_float })
        hl('WhichKeyGroup',     { fg = c.indigo })
        hl('WhichKeySeparator', { fg = c.lime })
        hl('WhichKeyValue',     { fg = c.muted })
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
