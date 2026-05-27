local M = {}
local hex_re = vim.regex('#\\x\\x\\x\\x\\x\\x')

local HEX_DIGITS = {
    ['0']=0, ['1']=1, ['2']=2, ['3']=3, ['4']=4,
    ['5']=5, ['6']=6, ['7']=7, ['8']=8, ['9']=9,
    ['a']=10, ['b']=11, ['c']=12, ['d']=13, ['e']=14, ['f']=15,
    ['A']=10, ['B']=11, ['C']=12, ['D']=13, ['E']=14, ['F']=15,
}

local function hex_to_rgb(hex)
    return HEX_DIGITS[hex:sub(1,1)]*16 + HEX_DIGITS[hex:sub(2,2)],
           HEX_DIGITS[hex:sub(3,3)]*16 + HEX_DIGITS[hex:sub(4,4)],
           HEX_DIGITS[hex:sub(5,5)]*16 + HEX_DIGITS[hex:sub(6,6)]
end

local function rgb_to_hex(r, g, b)
    return bit.tohex(bit.bor(bit.lshift(r, 16), bit.lshift(g, 8), b), 6)
end

local function darken(hex, pct)
    local r, g, b = hex_to_rgb(hex:sub(2))
    local k = 1 - pct
    return '#' .. rgb_to_hex(math.floor(r*k), math.floor(g*k), math.floor(b*k))
end

--[[
  Base24 semantic palette — 9 neutrals + 15 pastel accents = 24 slots.

  Neutral band (dark → bright):
    bg, bg_alt, surface, overlay, muted, subtle, fg, fg_alt, bright

  Pastel core (9):  red orange yellow green teal sky blue lavender pink
  Vivid extensions (6):  flame amber lime cyan indigo mauve

  The vivid layer provides a brighter, more saturated counterpart for each
  hue family so highlights can distinguish "the thing" from "the built-in
  variant of the thing" without relying on italic alone.
]]
local default_palette = {
    -- neutrals (dark → bright)
    bg       = '#272932',   -- editor background
    bg_alt   = '#31333f',   -- panels, floats, statusline
    surface  = '#3d4055',   -- selection, visual highlight
    overlay  = '#565a72',   -- borders, separators
    muted    = '#7b7f98',   -- comments, deemphasised text
    subtle   = '#9498b3',   -- line numbers, subtle UI
    fg       = '#d4d7e9',   -- primary foreground
    fg_alt   = '#eaecf5',   -- bright foreground (titles, panels)
    bright   = '#f5f6fb',   -- maximum brightness / soft white

    -- pastel core
    red      = '#e8a0a0',   -- errors, exceptions, delete
    orange   = '#e8b88a',   -- constants, numbers, branches
    yellow   = '#e8d99a',   -- types, warnings, labels, storage
    green    = '#a8d4a8',   -- strings, success, additions
    teal     = '#8ecec8',   -- special chars, regex, hints
    sky      = '#a0cce0',   -- identifiers, properties, info
    blue     = '#9ab8e0',   -- functions, directories, includes
    lavender = '#b8a8e8',   -- keywords, operators, conditionals
    pink     = '#e0a8c8',   -- delimiters, punctuation

    -- vivid extensions
    flame    = '#e07878',   -- macros, func-macros, critical errors
    amber    = '#d4a868',   -- attributes, annotations, warnings-vivid
    lime     = '#b8d888',   -- constructors, enum members, gutter-add
    cyan     = '#78ccd8',   -- builtins (func/const/var), special funcs
    indigo   = '#8898d8',   -- namespaces, modules, import, type-builtins
    mauve    = '#c098c8',   -- operators, punctuation-special, markup-em
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
        { notify = true, cmp = true, lsp_semantic = true, mini_completion = true, diffview = true, which_key = true },
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
    hl('NormalFloat',   { fg = c.fg,      bg = c.bg_alt })
    hl('FloatBorder',   { fg = c.overlay, bg = c.bg_alt })
    hl('FloatTitle',    { fg = c.blue,    bg = c.bg_alt, gui = 'bold' })

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

    -- ── Search ────────────────────────────────────────────────────────
    hl('Search',        { fg = c.bg,      bg = c.yellow })
    hl('IncSearch',     { fg = c.bg,      bg = c.amber,  gui = 'bold' })
    hl('Substitute',    { fg = c.bg,      bg = c.orange })
    hl('CurSearch',     { fg = c.bg,      bg = c.amber })

    -- ── UI chrome ─────────────────────────────────────────────────────
    hl('StatusLine',    { fg = c.fg,      bg = c.surface, gui = 'none' })
    hl('StatusLineNC',  { fg = c.subtle,  bg = c.bg_alt,  gui = 'none' })
    hl('WinBar',        { fg = c.fg,      gui = 'none' })
    hl('WinBarNC',      { fg = c.subtle,  gui = 'none' })
    hl('VertSplit',     { fg = c.overlay })
    hl('WinSeparator',  { fg = c.overlay })
    hl('TabLine',       { fg = c.muted,   bg = c.bg_alt,  gui = 'none' })
    hl('TabLineFill',   { fg = c.muted,   bg = c.bg_alt,  gui = 'none' })
    hl('TabLineSel',    { fg = c.lime,    bg = c.bg_alt,  gui = 'bold' })
    hl('Title',         { fg = c.blue,    gui = 'bold' })
    hl('Directory',     { fg = c.cyan })

    hl('ColorColumn',   { bg = c.bg_alt })
    hl('CursorColumn',  { bg = c.bg_alt })
    hl('CursorLine',    { bg = c.bg_alt })
    hl('CursorLineNr',  { fg = c.subtle,  bg = c.bg_alt })
    hl('LineNr',        { fg = c.muted,   bg = c.bg })
    hl('SignColumn',    { fg = c.muted,   bg = c.bg })
    hl('FoldColumn',    { fg = c.overlay, bg = c.bg })
    hl('Folded',        { fg = c.muted,   bg = c.bg_alt })
    hl('QuickFixLine',  { bg = c.bg_alt })
    hl('NonText',       { fg = c.overlay })
    hl('SpecialKey',    { fg = c.overlay })
    hl('Conceal',       { fg = c.overlay })
    hl('Whitespace',    { fg = c.overlay })

    -- ── Popup menu ────────────────────────────────────────────────────
    hl('PMenu',         { fg = c.fg,      bg = c.bg_alt })
    hl('PMenuSel',      { fg = c.bg,      bg = c.blue })
    hl('PMenuSbar',     { bg = c.surface })
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
    local diff_add_bg    = hex_re:match_str(c.green) and darken(c.green,  0.65) or c.bg
    local diff_del_bg    = hex_re:match_str(c.red)   and darken(c.red,    0.65) or c.bg
    local diff_change_bg = hex_re:match_str(c.amber) and darken(c.amber,  0.75) or c.bg
    local diff_text_bg   = hex_re:match_str(c.green) and darken(c.green,  0.55) or c.bg_alt

    hl('DiffAdd',       { bg = diff_add_bg })
    hl('DiffDelete',    { bg = diff_del_bg })
    hl('DiffChange',    { bg = diff_change_bg })
    hl('DiffText',      { bg = diff_text_bg,  gui = 'bold' })
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
    hl('LspReferenceText',  { gui = 'underline', sp = c.subtle })
    hl('LspReferenceRead',  { gui = 'underline', sp = c.subtle })
    hl('LspReferenceWrite', { gui = 'underline', sp = c.amber })
    hl('LspInlayHint',      { fg = c.muted,      gui = 'italic' })

    -- ── Treesitter (legacy TS* names) ─────────────────────────────────
    hl('TSAnnotation',          { fg = c.mauve,    gui = 'none' })
    hl('TSAttribute',           { fg = c.amber,    gui = 'none' })
    hl('TSBoolean',             { fg = c.orange,   gui = 'none' })
    hl('TSCharacter',           { fg = c.green,    gui = 'none' })
    hl('TSComment',             { fg = c.muted,    gui = 'italic' })
    hl('TSConstructor',         { fg = c.lime,     gui = 'none' })
    hl('TSConditional',         { fg = c.lavender, gui = 'none' })
    hl('TSConstant',            { fg = c.orange,   gui = 'none' })
    hl('TSConstBuiltin',        { fg = c.cyan,     gui = 'italic' })
    hl('TSConstMacro',          { fg = c.flame,    gui = 'none' })
    hl('TSError',               { fg = c.red,      gui = 'none' })
    hl('TSException',           { fg = c.red,      gui = 'none' })
    hl('TSField',               { fg = c.sky,      gui = 'none' })
    hl('TSFloat',               { fg = c.orange,   gui = 'none' })
    hl('TSFunction',            { fg = c.blue,     gui = 'none' })
    hl('TSFuncBuiltin',         { fg = c.cyan,     gui = 'italic' })
    hl('TSFuncMacro',           { fg = c.flame,    gui = 'none' })
    hl('TSInclude',             { fg = c.indigo,   gui = 'none' })
    hl('TSKeyword',             { fg = c.lavender, gui = 'none' })
    hl('TSKeywordFunction',     { fg = c.lavender, gui = 'none' })
    hl('TSKeywordOperator',     { fg = c.mauve,    gui = 'none' })
    hl('TSLabel',               { fg = c.yellow,   gui = 'none' })
    hl('TSMethod',              { fg = c.sky,      gui = 'none' })
    hl('TSNamespace',           { fg = c.indigo,   gui = 'none' })
    hl('TSNone',                { fg = c.fg,       gui = 'none' })
    hl('TSNumber',              { fg = c.orange,   gui = 'none' })
    hl('TSOperator',            { fg = c.mauve,    gui = 'none' })
    hl('TSParameter',           { fg = c.fg,       gui = 'none' })
    hl('TSParameterReference',  { fg = c.fg,       gui = 'none' })
    hl('TSProperty',            { fg = c.sky,      gui = 'none' })
    hl('TSPunctDelimiter',      { fg = c.pink,     gui = 'none' })
    hl('TSPunctBracket',        { fg = c.subtle,   gui = 'none' })
    hl('TSPunctSpecial',        { fg = c.mauve,    gui = 'none' })
    hl('TSRepeat',              { fg = c.lavender, gui = 'none' })
    hl('TSString',              { fg = c.green,    gui = 'none' })
    hl('TSStringRegex',         { fg = c.teal,     gui = 'none' })
    hl('TSStringEscape',        { fg = c.cyan,     gui = 'none' })
    hl('TSSymbol',              { fg = c.lime,     gui = 'none' })
    hl('TSTag',                 { fg = c.amber,    gui = 'none' })
    hl('TSTagDelimiter',        { fg = c.pink,     gui = 'none' })
    hl('TSText',                { fg = c.fg,       gui = 'none' })
    hl('TSStrong',              { gui = 'bold' })
    hl('TSEmphasis',            { fg = c.mauve,    gui = 'italic' })
    hl('TSUnderline',           { gui = 'underline' })
    hl('TSStrike',              { gui = 'strikethrough' })
    hl('TSTitle',               { fg = c.blue,     gui = 'bold' })
    hl('TSLiteral',             { fg = c.teal,     gui = 'none' })
    hl('TSURI',                 { fg = c.sky,      gui = 'underline' })
    hl('TSType',                { fg = c.yellow,   gui = 'none' })
    hl('TSTypeBuiltin',         { fg = c.indigo,   gui = 'italic' })
    hl('TSVariable',            { fg = c.fg,       gui = 'none' })
    hl('TSVariableBuiltin',     { fg = c.cyan,     gui = 'italic' })
    hl('TSDefinition',          { gui = 'underline', sp = c.subtle })
    hl('TSDefinitionUsage',     { gui = 'underline', sp = c.subtle })
    hl('TSCurrentScope',        { gui = 'bold' })

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
        hl('DiffviewCursorLine',          { bg = c.bg_alt })
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
        hl('DiffviewDiffAddAsDelete',     { fg = c.flame,   bg = diff_del_bg })
        hl('DiffviewDiffDelete',          { fg = c.muted,   bg = c.bg })
    end

    -- ── Which-key ─────────────────────────────────────────────────────
    if M.config.which_key then
        hl('WhichKey',          { fg = c.cyan })
        hl('WhichKeyDesc',      { fg = c.fg })
        hl('WhichKeyFloat',     { fg = c.fg,      bg = c.bg_alt })
        hl('WhichKeyGroup',     { fg = c.indigo })
        hl('WhichKeySeparator', { fg = c.lime })
        hl('WhichKeyValue',     { fg = c.muted })
    end

    if M.config.mini_completion then
        hl('MiniCompletionActiveParameter', 'CursorLine')
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
