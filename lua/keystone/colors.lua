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

-- darken by `pct` fraction (0 = unchanged, 1 = black)
local function darken(hex, pct)
    local r, g, b = hex_to_rgb(hex:sub(2))
    local k = 1 - pct
    return '#' .. rgb_to_hex(math.floor(r*k), math.floor(g*k), math.floor(b*k))
end

--[[
  Palette uses semantic names instead of base16 slots.
  18 colors: 9 neutrals (bg → bright) + 9 pastel accents.
  Callers may supply any subset; missing keys fall back to defaults.
]]
local default_palette = {
    -- neutrals (dark → bright)
    bg       = '#272932',   -- editor background
    bg_alt   = '#31333f',   -- panels, floats, statusline
    surface  = 'FF5F6798',   -- selection, visual
    overlay  = '#565a72',   -- borders, separators
    muted    = '#7b7f98',   -- comments, deemphasized text
    subtle   = '#9498b3',   -- line numbers, subtle UI
    fg       = '#d4d7e9',   -- primary foreground
    fg_alt   = '#eaecf5',   -- bright foreground (titles, panels)
    bright   = '#f5f6fb',   -- maximum brightness / soft white

    -- accents (pastel)
    red      = '#e8a0a0',   -- errors, exceptions, tags
    orange   = '#e8b88a',   -- constants, numbers, branches
    yellow   = '#e8d99a',   -- types, warnings, labels, storage
    green    = '#a8d4a8',   -- strings, success, additions
    teal     = '#8ecec8',   -- special chars, regex, hints
    sky      = '#a0cce0',   -- identifiers, URIs, info
    blue     = '#9ab8e0',   -- functions, directories, includes
    lavender = '#b8a8e8',   -- keywords, operators, conditionals
    pink     = '#e0a8c8',   -- delimiters, punctuation, misc
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
    hl('FloatTitle',    { fg = c.blue,    bg = c.bg_alt })

    hl('Bold',          { gui = 'bold' })
    hl('Italic',        { gui = 'italic' })
    hl('Underlined',    { fg = c.blue,    gui = 'underline' })

    -- ── Cursor & selection ────────────────────────────────────────────
    hl('Cursor',        { fg = c.bg,      bg = c.fg })
    hl('TermCursor',    { fg = c.bg,      bg = c.fg })
    hl('TermCursorNC',  { fg = c.bg,      bg = c.muted })
    hl('Visual',        { bg = c.surface })
    hl('VisualNOS',     { bg = c.surface })
    hl('MatchParen',    { bg = c.overlay, gui = 'bold' })

    -- ── Search ────────────────────────────────────────────────────────
    hl('Search',        { fg = c.bg,      bg = c.yellow })
    hl('IncSearch',     { fg = c.bg,      bg = c.orange, gui = 'bold' })
    hl('Substitute',    { fg = c.bg,      bg = c.orange })
    hl('CurSearch',     { fg = c.bg,      bg = c.orange })

    -- ── UI chrome ─────────────────────────────────────────────────────
    hl('StatusLine',    { fg = c.fg,      bg = c.surface, gui = 'none' })
    hl('StatusLineNC',  { fg = c.subtle,  bg = c.bg_alt,  gui = 'none' })
    hl('WinBar',        { fg = c.fg,      gui = 'none' })
    hl('WinBarNC',      { fg = c.subtle,  gui = 'none' })
    hl('VertSplit',     { fg = c.overlay })
    hl('WinSeparator',  { fg = c.overlay })
    hl('TabLine',       { fg = c.muted,   bg = c.bg_alt,  gui = 'none' })
    hl('TabLineFill',   { fg = c.muted,   bg = c.bg_alt,  gui = 'none' })
    hl('TabLineSel',    { fg = c.green,   bg = c.bg_alt,  gui = 'none' })
    hl('Title',         { fg = c.blue,    gui = 'bold' })
    hl('Directory',     { fg = c.blue })

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
    hl('ModeMsg',       { fg = c.green })
    hl('MoreMsg',       { fg = c.green })
    hl('Question',      { fg = c.blue })
    hl('WarningMsg',    { fg = c.yellow })
    hl('ErrorMsg',      { fg = c.red,     bg = c.bg })
    hl('Error',         { fg = c.red,     bg = c.bg })
    hl('Debug',         { fg = c.red })
    hl('TooLong',       { fg = c.red })
    hl('WildMenu',      { fg = c.bg,      bg = c.yellow })

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
    hl('Operator',      { fg = c.lavender, gui = 'none' })
    hl('Exception',     { fg = c.red })
    hl('Macro',         { fg = c.red })
    hl('PreProc',       { fg = c.blue })
    hl('Include',       { fg = c.blue })
    hl('Define',        { fg = c.lavender, gui = 'none' })
    hl('Type',          { fg = c.yellow,  gui = 'none' })
    hl('Typedef',       { fg = c.yellow })
    hl('StorageClass',  { fg = c.yellow })
    hl('Structure',     { fg = c.yellow })
    hl('Special',       { fg = c.teal })
    hl('SpecialChar',   { fg = c.teal })
    hl('Tag',           { fg = c.yellow })
    hl('Label',         { fg = c.yellow })
    hl('Delimiter',     { fg = c.pink })
    hl('Todo',          { fg = c.yellow,  bg = c.bg_alt })

    -- ── Diff ──────────────────────────────────────────────────────────
    local diff_add_bg    = hex_re:match_str(c.green)  and darken(c.green,  0.65) or c.bg
    local diff_del_bg    = hex_re:match_str(c.red)    and darken(c.red,    0.65) or c.bg
    local diff_change_bg = hex_re:match_str(c.orange) and darken(c.orange, 0.75) or c.bg
    local diff_text_bg   = hex_re:match_str(c.green)  and darken(c.green,  0.55) or c.bg_alt

    hl('DiffAdd',       { bg = diff_add_bg })
    hl('DiffDelete',    { bg = diff_del_bg })
    hl('DiffChange',    { bg = diff_change_bg })
    hl('DiffText',      { bg = diff_text_bg,  gui = 'bold' })
    hl('DiffAdded',     { fg = c.green,       bg = c.bg })
    hl('DiffRemoved',   { fg = c.red,         bg = c.bg })
    hl('DiffFile',      { fg = c.red,         bg = c.bg })
    hl('DiffNewFile',   { fg = c.green,       bg = c.bg })
    hl('DiffLine',      { fg = c.blue,        bg = c.bg })

    -- ── Git ───────────────────────────────────────────────────────────
    hl('gitcommitSummary',        { fg = c.green })
    hl('gitcommitComment',        { fg = c.muted })
    hl('gitcommitOverflow',       { fg = c.red })
    hl('gitcommitUntracked',      { fg = c.muted })
    hl('gitcommitDiscarded',      { fg = c.muted })
    hl('gitcommitSelected',       { fg = c.muted })
    hl('gitcommitHeader',         { fg = c.lavender })
    hl('gitcommitSelectedType',   { fg = c.blue })
    hl('gitcommitUnmergedType',   { fg = c.blue })
    hl('gitcommitDiscardedType',  { fg = c.blue })
    hl('gitcommitBranch',         { fg = c.orange,   gui = 'bold' })
    hl('gitcommitUntrackedFile',  { fg = c.yellow })
    hl('gitcommitUnmergedFile',   { fg = c.red,      gui = 'bold' })
    hl('gitcommitDiscardedFile',  { fg = c.red,      gui = 'bold' })
    hl('gitcommitSelectedFile',   { fg = c.green,    gui = 'bold' })

    hl('GitGutterAdd',            { fg = c.green,    bg = c.bg })
    hl('GitGutterChange',         { fg = c.blue,     bg = c.bg })
    hl('GitGutterDelete',         { fg = c.red,      bg = c.bg })
    hl('GitGutterChangeDelete',   { fg = c.lavender, bg = c.bg })

    -- ── Spell ─────────────────────────────────────────────────────────
    hl('SpellBad',      { gui = 'undercurl', sp = c.red })
    hl('SpellLocal',    { gui = 'undercurl', sp = c.teal })
    hl('SpellCap',      { gui = 'undercurl', sp = c.blue })
    hl('SpellRare',     { gui = 'undercurl', sp = c.lavender })

    -- ── Diagnostics ───────────────────────────────────────────────────
    hl('DiagnosticError',               { fg = c.red })
    hl('DiagnosticWarn',                { fg = c.yellow })
    hl('DiagnosticInfo',                { fg = c.blue })
    hl('DiagnosticHint',                { fg = c.teal })
    hl('DiagnosticUnderlineError',      { gui = 'undercurl', sp = c.red })
    hl('DiagnosticUnderlineWarning',    { gui = 'undercurl', sp = c.yellow })
    hl('DiagnosticUnderlineWarn',       { gui = 'undercurl', sp = c.yellow })
    hl('DiagnosticUnderlineInformation',{ gui = 'undercurl', sp = c.sky })
    hl('DiagnosticUnderlineHint',       { gui = 'undercurl', sp = c.teal })

    -- ── LSP ───────────────────────────────────────────────────────────
    hl('LspReferenceText',  { gui = 'underline', sp = c.subtle })
    hl('LspReferenceRead',  { gui = 'underline', sp = c.subtle })
    hl('LspReferenceWrite', { gui = 'underline', sp = c.subtle })

    -- ── Treesitter ────────────────────────────────────────────────────
    hl('TSAnnotation',          { fg = c.pink,     gui = 'none' })
    hl('TSAttribute',           { fg = c.yellow,   gui = 'none' })
    hl('TSBoolean',             { fg = c.orange,   gui = 'none' })
    hl('TSCharacter',           { fg = c.green,    gui = 'none' })
    hl('TSComment',             { fg = c.muted,    gui = 'italic' })
    hl('TSConstructor',         { fg = c.blue,     gui = 'none' })
    hl('TSConditional',         { fg = c.lavender, gui = 'none' })
    hl('TSConstant',            { fg = c.orange,   gui = 'none' })
    hl('TSConstBuiltin',        { fg = c.orange,   gui = 'italic' })
    hl('TSConstMacro',          { fg = c.red,      gui = 'none' })
    hl('TSError',               { fg = c.red,      gui = 'none' })
    hl('TSException',           { fg = c.red,      gui = 'none' })
    hl('TSField',               { fg = c.fg,       gui = 'none' })
    hl('TSFloat',               { fg = c.orange,   gui = 'none' })
    hl('TSFunction',            { fg = c.blue,     gui = 'none' })
    hl('TSFuncBuiltin',         { fg = c.blue,     gui = 'italic' })
    hl('TSFuncMacro',           { fg = c.red,      gui = 'none' })
    hl('TSInclude',             { fg = c.blue,     gui = 'none' })
    hl('TSKeyword',             { fg = c.lavender, gui = 'none' })
    hl('TSKeywordFunction',     { fg = c.lavender, gui = 'none' })
    hl('TSKeywordOperator',     { fg = c.lavender, gui = 'none' })
    hl('TSLabel',               { fg = c.yellow,   gui = 'none' })
    hl('TSMethod',              { fg = c.blue,     gui = 'none' })
    hl('TSNamespace',           { fg = c.orange,   gui = 'none' })
    hl('TSNone',                { fg = c.fg,       gui = 'none' })
    hl('TSNumber',              { fg = c.orange,   gui = 'none' })
    hl('TSOperator',            { fg = c.fg,       gui = 'none' })
    hl('TSParameter',           { fg = c.fg,       gui = 'none' })
    hl('TSParameterReference',  { fg = c.fg,       gui = 'none' })
    hl('TSProperty',            { fg = c.fg,       gui = 'none' })
    hl('TSPunctDelimiter',      { fg = c.pink,     gui = 'none' })
    hl('TSPunctBracket',        { fg = c.fg,       gui = 'none' })
    hl('TSPunctSpecial',        { fg = c.pink,     gui = 'none' })
    hl('TSRepeat',              { fg = c.lavender, gui = 'none' })
    hl('TSString',              { fg = c.green,    gui = 'none' })
    hl('TSStringRegex',         { fg = c.teal,     gui = 'none' })
    hl('TSStringEscape',        { fg = c.teal,     gui = 'none' })
    hl('TSSymbol',              { fg = c.green,    gui = 'none' })
    hl('TSTag',                 { fg = c.red,      gui = 'none' })
    hl('TSTagDelimiter',        { fg = c.pink,     gui = 'none' })
    hl('TSText',                { fg = c.fg,       gui = 'none' })
    hl('TSStrong',              { gui = 'bold' })
    hl('TSEmphasis',            { fg = c.orange,   gui = 'italic' })
    hl('TSUnderline',           { gui = 'underline' })
    hl('TSStrike',              { gui = 'strikethrough' })
    hl('TSTitle',               { fg = c.blue,     gui = 'bold' })
    hl('TSLiteral',             { fg = c.orange,   gui = 'none' })
    hl('TSURI',                 { fg = c.sky,      gui = 'underline' })
    hl('TSType',                { fg = c.yellow,   gui = 'none' })
    hl('TSTypeBuiltin',         { fg = c.yellow,   gui = 'italic' })
    hl('TSVariable',            { fg = c.fg,       gui = 'none' })
    hl('TSVariableBuiltin',     { fg = c.sky,      gui = 'italic' })
    hl('TSDefinition',          { gui = 'underline', sp = c.subtle })
    hl('TSDefinitionUsage',     { gui = 'underline', sp = c.subtle })
    hl('TSCurrentScope',        { gui = 'bold' })

    hl('NvimInternalError',     { fg = c.bg,  bg = c.red })

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
        hl('DiffviewFilePanelInsertions', { fg = c.green,   gui = 'bold' })
        hl('DiffviewFilePanelDeletions',  { fg = c.red,     gui = 'bold' })
        hl('DiffviewStatusAdded',         { fg = c.green,   gui = 'bold' })
        hl('DiffviewStatusUntracked',     { fg = c.green })
        hl('DiffviewStatusModified',      { fg = c.yellow,  gui = 'bold' })
        hl('DiffviewStatusRenamed',       { fg = c.blue,    gui = 'bold' })
        hl('DiffviewStatusCopied',        { fg = c.blue })
        hl('DiffviewStatusTypeChange',    { fg = c.lavender, gui = 'bold' })
        hl('DiffviewStatusDeleted',       { fg = c.red,     gui = 'bold' })
        hl('DiffviewStatusBroken',        { fg = c.red,     gui = 'bold' })
        hl('DiffviewStatusUnknown',       { fg = c.red })
        hl('DiffviewStatusUnmerged',      { fg = c.lavender, gui = 'bold' })
        hl('DiffviewDiffAddAsDelete',     { fg = c.red,     bg = diff_del_bg })
        hl('DiffviewDiffDelete',          { fg = c.muted,   bg = c.bg })
    end

    -- ── Which-key ─────────────────────────────────────────────────────
    if M.config.which_key then
        hl('WhichKey',          { fg = c.blue })
        hl('WhichKeyDesc',      { fg = c.fg })
        hl('WhichKeyFloat',     { fg = c.fg,    bg = c.bg_alt })
        hl('WhichKeyGroup',     { fg = c.lavender })
        hl('WhichKeySeparator', { fg = c.green })
        hl('WhichKeyValue',     { fg = c.muted })
    end

    if M.config.mini_completion then
        hl('MiniCompletionActiveParameter', 'CursorLine')
    end

    -- ── Terminal colors ───────────────────────────────────────────────
    vim.g.terminal_color_0  = c.bg
    vim.g.terminal_color_1  = c.red
    vim.g.terminal_color_2  = c.green
    vim.g.terminal_color_3  = c.yellow
    vim.g.terminal_color_4  = c.blue
    vim.g.terminal_color_5  = c.lavender
    vim.g.terminal_color_6  = c.teal
    vim.g.terminal_color_7  = c.fg
    vim.g.terminal_color_8  = c.muted
    vim.g.terminal_color_9  = c.red
    vim.g.terminal_color_10 = c.green
    vim.g.terminal_color_11 = c.yellow
    vim.g.terminal_color_12 = c.sky
    vim.g.terminal_color_13 = c.pink
    vim.g.terminal_color_14 = c.sky
    vim.g.terminal_color_15 = c.bright
end

return M
