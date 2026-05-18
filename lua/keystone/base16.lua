local M = {}
local hex_re = vim.regex('#\\x\\x\\x\\x\\x\\x')

local HEX_DIGITS = {
    ['0'] = 0,
    ['1'] = 1,
    ['2'] = 2,
    ['3'] = 3,
    ['4'] = 4,
    ['5'] = 5,
    ['6'] = 6,
    ['7'] = 7,
    ['8'] = 8,
    ['9'] = 9,
    ['a'] = 10,
    ['b'] = 11,
    ['c'] = 12,
    ['d'] = 13,
    ['e'] = 14,
    ['f'] = 15,
    ['A'] = 10,
    ['B'] = 11,
    ['C'] = 12,
    ['D'] = 13,
    ['E'] = 14,
    ['F'] = 15,
}

local function hex_to_rgb(hex)
    return HEX_DIGITS[string.sub(hex, 1, 1)] * 16 + HEX_DIGITS[string.sub(hex, 2, 2)],
        HEX_DIGITS[string.sub(hex, 3, 3)] * 16 + HEX_DIGITS[string.sub(hex, 4, 4)],
        HEX_DIGITS[string.sub(hex, 5, 5)] * 16 + HEX_DIGITS[string.sub(hex, 6, 6)]
end

local function rgb_to_hex(r, g, b)
    return bit.tohex(bit.bor(bit.lshift(r, 16), bit.lshift(g, 8), b), 6)
end

local function darken(hex, pct)
    pct = 1 - pct
    local r, g, b = hex_to_rgb(string.sub(hex, 2))
    r = math.floor(r * pct)
    g = math.floor(g * pct)
    b = math.floor(b * pct)
    return string.format("#%s", rgb_to_hex(r, g, b))
end

local default_palette = {
    -- neutrals
    base00 = '#2e2f33', -- background
    base01 = '#3a3b40', -- panels / statusline
    base02 = '#505157', -- selection / visual bg
    base03 = '#6e6f77', -- comments / muted text
    base04 = '#a0a2ad', -- subtle ui highlights
    base05 = '#dcdce4', -- primary foreground
    base06 = '#f2f2f5', -- bright foreground
    base07 = '#fafafd', -- soft white

    -- accents
    base08 = '#e79c9c', -- red
    base09 = '#f2c38f', -- orange
    base0A = '#f5e6a6', -- yellow
    base0B = '#b1d7b4', -- green
    base0C = '#a8d8e1', -- cyan
    base0D = '#aabbe0', -- blue
    base0E = '#cbb0e3', -- purple
    base0F = '#e5c1c5', -- rose
}

---@param hlgroup string
---@param args string|{guifg:string?,guibg:string?,gui:string?,guisp:string?,ctermfg:string?,ctermbg:string?}
local function _highlight(hlgroup, args)
    if 'string' == type(args) then
        vim.api.nvim_set_hl(0, hlgroup, { link = args })
        return
    end

    local guifg, guibg, gui, guisp = args.guifg or nil, args.guibg or nil, args.gui or nil, args.guisp or nil
    local ctermfg, ctermbg = args.ctermfg or nil, args.ctermbg or nil
    local val = {}

    if guifg then val.fg = guifg end
    if guibg then val.bg = guibg end
    if ctermfg then val.ctermfg = ctermfg end
    if ctermbg then val.ctermbg = ctermbg end
    if guisp then val.sp = guisp end
    if gui then
        for x in string.gmatch(gui, '([^,]+)') do
            if x ~= "none" then
                val[x] = true
            end
        end
    end
    vim.api.nvim_set_hl(0, hlgroup, val)
end

function M.with_config(config)
    M.config = vim.tbl_extend("force",
        { notify = true, cmp = true, lsp_semantic = true, mini_completion = true, diffview = true, which_key = true
        }, config or M.config or {})
end

--
function M.setup(config)
    M.with_config(config)

    if vim.fn.exists('syntax_on') then
        vim.cmd('syntax reset')
    end

    M.colors = (config.palette and next(config.palette) ~= nil) and config.palette or default_palette

    local hl = _highlight

    hl('Normal',
        {
            guifg = M.colors.base05,
            guibg = M.colors.base00,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm05,
            ctermbg =
                M.colors.cterm00
        })

    hl('Bold', { guifg = nil, guibg = nil, gui = 'bold', guisp = nil, ctermfg = nil, ctermbg = nil })

    hl('Debug',
        { guifg = M.colors.base08, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('Directory',
        { guifg = M.colors.base0D, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })

    hl('Error',
        {
            guifg = M.colors.base08,
            guibg = M.colors.base00,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm08,
            ctermbg =
                M.colors.cterm00
        })

    hl('ErrorMsg',
        {
            guifg = M.colors.base08,
            guibg = M.colors.base00,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm08,
            ctermbg =
                M.colors.cterm00
        })

    hl('Exception',
        { guifg = M.colors.base08, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('FoldColumn',
        {
            guifg = M.colors.base0C,
            guibg = M.colors.base00,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm0C,
            ctermbg =
                M.colors.cterm00
        })

    hl('Folded',
        {
            guifg = M.colors.base03,
            guibg = M.colors.base01,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm03,
            ctermbg =
                M.colors.cterm01
        })

    hl('IncSearch',
        {
            guifg = M.colors.base01,
            guibg = M.colors.base09,
            gui = 'none',
            guisp = nil,
            ctermfg = M.colors.cterm01,
            ctermbg =
                M.colors.cterm09
        })

    hl('Italic', { guifg = nil, guibg = nil, gui = 'italic', guisp = nil, ctermfg = nil, ctermbg = nil })

    hl('Macro',
        { guifg = M.colors.base08, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('MatchParen',
        { guifg = nil, guibg = M.colors.base03, gui = nil, guisp = nil, ctermfg = nil, ctermbg = M.colors.cterm03 })

    hl('ModeMsg',
        { guifg = M.colors.base0B, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0B, ctermbg = nil })

    hl('MoreMsg',
        { guifg = M.colors.base0B, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0B, ctermbg = nil })

    hl('Question',
        { guifg = M.colors.base0D, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })

    hl('Search',
        {
            guifg = M.colors.base01,
            guibg = M.colors.base0A,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm01,
            ctermbg =
                M.colors.cterm0A
        })


    hl('Substitute',
        {
            guifg = M.colors.base01,
            guibg = M.colors.base0A,
            gui = 'none',
            guisp = nil,
            ctermfg = M.colors.cterm01,
            ctermbg =
                M.colors.cterm0A
        })

    hl('SpecialKey',
        { guifg = M.colors.base03, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm03, ctermbg = nil })

    hl('TooLong',
        { guifg = M.colors.base08, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('Underlined',
        { guifg = M.colors.base08, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('Visual',
        { guifg = nil, guibg = M.colors.base02, gui = nil, guisp = nil, ctermfg = nil, ctermbg = M.colors.cterm02 })

    hl('VisualNOS',
        { guifg = M.colors.base08, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('WarningMsg',
        { guifg = M.colors.base08, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('WildMenu',
        {
            guifg = M.colors.base08,
            guibg = M.colors.base0A,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm08,
            ctermbg =
                M.colors.cterm0A
        })

    hl('Title',
        { guifg = M.colors.base0D, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })

    hl('Conceal',
        {
            guifg = M.colors.base0D,
            guibg = M.colors.base00,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm0D,
            ctermbg =
                M.colors.cterm00
        })

    hl('Cursor',
        {
            guifg = M.colors.base00,
            guibg = M.colors.base05,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm00,
            ctermbg =
                M.colors.cterm05
        })

    hl('NonText',
        { guifg = M.colors.base03, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm03, ctermbg = nil })

    hl('LineNr',
        {
            guifg = M.colors.base04,
            guibg = M.colors.base00,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm04,
            ctermbg =
                M.colors.cterm00
        })

    hl('SignColumn',
        {
            guifg = M.colors.base04,
            guibg = M.colors.base00,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm04,
            ctermbg =
                M.colors.cterm00
        })

    hl('StatusLine',
        {
            guifg = M.colors.base05,
            guibg = M.colors.base02,
            gui = 'none',
            guisp = nil,
            ctermfg = M.colors.cterm05,
            ctermbg =
                M.colors.cterm02
        })

    hl('StatusLineNC',
        {
            guifg = M.colors.base04,
            guibg = M.colors.base01,
            gui = 'none',
            guisp = nil,
            ctermfg = M.colors.cterm04,
            ctermbg =
                M.colors.cterm01
        })

    hl('WinBar',
        { guifg = M.colors.base05, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm05, ctermbg = nil })

    hl('WinBarNC',
        { guifg = M.colors.base04, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm04, ctermbg = nil })

    hl('VertSplit',
        {
            guifg = M.colors.base05,
            guibg = M.colors.base00,
            gui = 'none',
            guisp = nil,
            ctermfg = M.colors.cterm05,
            ctermbg =
                M.colors.cterm00
        })

    hl('ColorColumn',
        { guifg = nil, guibg = M.colors.base01, gui = 'none', guisp = nil, ctermfg = nil, ctermbg = M.colors.cterm01 })

    hl('CursorColumn',
        { guifg = nil, guibg = M.colors.base01, gui = 'none', guisp = nil, ctermfg = nil, ctermbg = M.colors.cterm01 })

    hl('CursorLine',
        { guifg = nil, guibg = M.colors.base01, gui = 'none', guisp = nil, ctermfg = nil, ctermbg = M.colors.cterm01 })

    hl('CursorLineNr',
        {
            guifg = M.colors.base04,
            guibg = M.colors.base01,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm04,
            ctermbg =
                M.colors.cterm01
        })

    hl('QuickFixLine',
        { guifg = nil, guibg = M.colors.base01, gui = 'none', guisp = nil, ctermfg = nil, ctermbg = M.colors.cterm01 })

    hl('PMenu',
        {
            guifg = M.colors.base05,
            guibg = M.colors.base01,
            gui = 'none',
            guisp = nil,
            ctermfg = M.colors.cterm05,
            ctermbg =
                M.colors.cterm01
        })

    hl('PMenuSel',
        {
            guifg = M.colors.base01,
            guibg = M.colors.base05,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm01,
            ctermbg =
                M.colors.cterm05
        })

    hl('TabLine',
        {
            guifg = M.colors.base03,
            guibg = M.colors.base01,
            gui = 'none',
            guisp = nil,
            ctermfg = M.colors.cterm03,
            ctermbg =
                M.colors.cterm01
        })

    hl('TabLineFill',
        {
            guifg = M.colors.base03,
            guibg = M.colors.base01,
            gui = 'none',
            guisp = nil,
            ctermfg = M.colors.cterm03,
            ctermbg =
                M.colors.cterm01
        })

    hl('TabLineSel',
        {
            guifg = M.colors.base0B,
            guibg = M.colors.base01,
            gui = 'none',
            guisp = nil,
            ctermfg = M.colors.cterm0B,
            ctermbg =
                M.colors.cterm01
        })

    -- Standard syntax highlighting
    hl('Boolean',
        { guifg = M.colors.base09, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm09, ctermbg = nil })

    hl('Character',
        { guifg = M.colors.base08, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('Comment',
        { guifg = M.colors.base03, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm03, ctermbg = nil })

    hl('Conditional',
        { guifg = M.colors.base0E, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0E, ctermbg = nil })

    hl('Constant',
        { guifg = M.colors.base09, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm09, ctermbg = nil })

    hl('Define',
        { guifg = M.colors.base0E, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0E, ctermbg = nil })

    hl('Delimiter',
        { guifg = M.colors.base0F, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0F, ctermbg = nil })

    hl('Float',
        { guifg = M.colors.base09, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm09, ctermbg = nil })

    hl('Function',
        { guifg = M.colors.base0D, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })

    hl('Identifier',
        { guifg = M.colors.base0C, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('Include',
        { guifg = M.colors.base0D, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })

    hl('Keyword',
        { guifg = M.colors.base0E, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0E, ctermbg = nil })

    hl('Label',
        { guifg = M.colors.base0A, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0A, ctermbg = nil })

    hl('Number',
        { guifg = M.colors.base09, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm09, ctermbg = nil })

    hl('Operator',
        { guifg = M.colors.base0E, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0E, ctermbg = nil })

    hl('PreProc',
        { guifg = M.colors.base0A, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0A, ctermbg = nil })

    hl('Repeat',
        { guifg = M.colors.base0A, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0A, ctermbg = nil })

    hl('Special',
        { guifg = M.colors.base0C, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0C, ctermbg = nil })

    hl('SpecialChar',
        { guifg = M.colors.base0F, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0F, ctermbg = nil })

    hl('Statement',
        { guifg = M.colors.base09, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('StorageClass',
        { guifg = M.colors.base0A, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0A, ctermbg = nil })

    hl('String',
        { guifg = M.colors.base0B, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0B, ctermbg = nil })

    hl('Structure',
        { guifg = M.colors.base0E, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0E, ctermbg = nil })

    hl('Tag', { guifg = M.colors.base0A, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0A, ctermbg = nil })

    hl('Todo',
        {
            guifg = M.colors.base0A,
            guibg = M.colors.base01,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm0A,
            ctermbg =
                M.colors.cterm01
        })

    hl('Type',
        { guifg = M.colors.base0D, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0A, ctermbg = nil })

    hl('Typedef',
        { guifg = M.colors.base0A, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0A, ctermbg = nil })


    -- Diff highlighting (GitHub-like style with subtle backgrounds)
    local diff_add_bg = hex_re:match_str(M.colors.base0B) and hex_re:match_str(M.colors.base00)
        and darken(M.colors.base0B, 0.6) or M.colors.base00

    local diff_delete_bg = hex_re:match_str(M.colors.base08) and hex_re:match_str(M.colors.base00)
        and darken(M.colors.base08, 0.6) or M.colors.base00

    local diff_change_bg = hex_re:match_str(M.colors.base09) and hex_re:match_str(M.colors.base00)
        and darken(M.colors.base09, 0.8) or M.colors.base00

    local diff_text_bg = hex_re:match_str(M.colors.base0B) and hex_re:match_str(M.colors.base00)
        and darken(M.colors.base0B, 0.7) or M.colors.base01

    hl('DiffAdd', { guifg = nil, guibg = diff_add_bg, gui = nil, guisp = nil, ctermfg = nil, ctermbg = M.colors.cterm00 })

    hl('DiffChange',
        { guifg = nil, guibg = diff_change_bg, gui = nil, guisp = nil, ctermfg = nil, ctermbg = M.colors.cterm00 })

    hl('DiffDelete',
        { guifg = nil, guibg = diff_delete_bg, gui = nil, guisp = nil, ctermfg = nil, ctermbg = M.colors.cterm00 })

    hl('DiffText',
        { guifg = nil, guibg = diff_text_bg, gui = 'bold', guisp = nil, ctermfg = nil, ctermbg = M.colors.cterm01 })

    hl('DiffAdded',
        {
            guifg = M.colors.base0B,
            guibg = M.colors.base00,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm0B,
            ctermbg =
                M.colors.cterm00
        })

    hl('DiffFile',
        {
            guifg = M.colors.base08,
            guibg = M.colors.base00,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm08,
            ctermbg =
                M.colors.cterm00
        })

    hl('DiffNewFile',
        {
            guifg = M.colors.base0B,
            guibg = M.colors.base00,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm0B,
            ctermbg =
                M.colors.cterm00
        })

    hl('DiffLine',
        {
            guifg = M.colors.base0D,
            guibg = M.colors.base00,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm0D,
            ctermbg =
                M.colors.cterm00
        })

    hl('DiffRemoved',
        {
            guifg = M.colors.base08,
            guibg = M.colors.base00,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm08,
            ctermbg =
                M.colors.cterm00
        })

    -- Diffview.nvim highlighting
    if M.config.diffview then
        hl('DiffviewNormal',
            {
                guifg = M.colors.base05,
                guibg = M.colors.base00,
                gui = nil,
                guisp = nil,
                ctermfg = M.colors.cterm05,
                ctermbg =
                    M.colors.cterm00
            })

        hl('DiffviewCursorLine',
            { guifg = nil, guibg = M.colors.base01, gui = nil, guisp = nil, ctermfg = nil, ctermbg = M.colors.cterm01 })

        hl('DiffviewSignColumn',
            {
                guifg = M.colors.base04,
                guibg = M.colors.base00,
                gui = nil,
                guisp = nil,
                ctermfg = M.colors.cterm04,
                ctermbg =
                    M.colors.cterm00
            })

        hl('DiffviewEndOfBuffer',
            { guifg = M.colors.base03, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm03, ctermbg = nil })

        hl('DiffviewLineNr',
            { guifg = M.colors.base04, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm04, ctermbg = nil })

        hl('DiffviewWinSeparator',
            { guifg = M.colors.base02, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm02, ctermbg = nil })

        -- File panel highlighting
        hl('DiffviewFilePanelTitle',
            { guifg = M.colors.base06, guibg = nil, gui = 'bold', guisp = nil, ctermfg = M.colors.cterm06, ctermbg = nil })

        hl('DiffviewFilePanelCounter',
            { guifg = M.colors.base04, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm04, ctermbg = nil })

        hl('DiffviewFilePanelFileName',
            { guifg = M.colors.base06, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm06, ctermbg = nil })

        hl('DiffviewFilePanelPath',
            { guifg = M.colors.base04, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm04, ctermbg = nil })

        hl('DiffviewFilePanelRootPath',
            { guifg = M.colors.base06, guibg = nil, gui = 'bold', guisp = nil, ctermfg = M.colors.cterm06, ctermbg = nil })

        hl('DiffviewFilePanelInsertions',
            { guifg = M.colors.base0B, guibg = nil, gui = 'bold', guisp = nil, ctermfg = M.colors.cterm0B, ctermbg = nil })

        hl('DiffviewFilePanelDeletions',
            { guifg = M.colors.base08, guibg = nil, gui = 'bold', guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

        -- Status highlighting
        hl('DiffviewStatusAdded',
            { guifg = M.colors.base0B, guibg = nil, gui = 'bold', guisp = nil, ctermfg = M.colors.cterm0B, ctermbg = nil })

        hl('DiffviewStatusUntracked',
            { guifg = M.colors.base0B, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0B, ctermbg = nil })

        hl('DiffviewStatusModified',
            { guifg = M.colors.base0A, guibg = nil, gui = 'bold', guisp = nil, ctermfg = M.colors.cterm0A, ctermbg = nil })

        hl('DiffviewStatusRenamed',
            { guifg = M.colors.base0D, guibg = nil, gui = 'bold', guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })

        hl('DiffviewStatusCopied',
            { guifg = M.colors.base0D, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })

        hl('DiffviewStatusTypeChange',
            { guifg = M.colors.base0E, guibg = nil, gui = 'bold', guisp = nil, ctermfg = M.colors.cterm0E, ctermbg = nil })

        hl('DiffviewStatusDeleted',
            { guifg = M.colors.base08, guibg = nil, gui = 'bold', guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

        hl('DiffviewStatusBroken',
            { guifg = M.colors.base08, guibg = nil, gui = 'bold', guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

        hl('DiffviewStatusUnknown',
            { guifg = M.colors.base08, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

        hl('DiffviewStatusUnmerged',
            { guifg = M.colors.base0E, guibg = nil, gui = 'bold', guisp = nil, ctermfg = M.colors.cterm0E, ctermbg = nil })

        -- Reference highlighting
        hl('DiffviewDiffAddAsDelete',
            {
                guifg = M.colors.base08,
                guibg = diff_delete_bg,
                gui = nil,
                guisp = nil,
                ctermfg = M.colors.cterm08,
                ctermbg =
                    M.colors.cterm00
            })

        hl('DiffviewDiffDelete',
            {
                guifg = M.colors.base03,
                guibg = M.colors.base00,
                gui = nil,
                guisp = nil,
                ctermfg = M.colors.cterm03,
                ctermbg =
                    M.colors.cterm00
            })
    end


    -- Git highlighting
    hl('gitcommitOverflow',
        { guifg = M.colors.base08, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('gitcommitSummary',
        { guifg = M.colors.base0B, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0B, ctermbg = nil })

    hl('gitcommitComment',
        { guifg = M.colors.base03, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm03, ctermbg = nil })

    hl('gitcommitUntracked',
        { guifg = M.colors.base03, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm03, ctermbg = nil })

    hl('gitcommitDiscarded',
        { guifg = M.colors.base03, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm03, ctermbg = nil })

    hl('gitcommitSelected',
        { guifg = M.colors.base03, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm03, ctermbg = nil })

    hl('gitcommitHeader',
        { guifg = M.colors.base0E, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0E, ctermbg = nil })

    hl('gitcommitSelectedType',
        { guifg = M.colors.base0D, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })

    hl('gitcommitUnmergedType',
        { guifg = M.colors.base0D, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })

    hl('gitcommitDiscardedType',
        { guifg = M.colors.base0D, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })

    hl('gitcommitBranch',
        { guifg = M.colors.base09, guibg = nil, gui = 'bold', guisp = nil, ctermfg = M.colors.cterm09, ctermbg = nil })

    hl('gitcommitUntrackedFile',
        { guifg = M.colors.base0A, guibg = nil, gui = nil, guisp = nil, ctermfg = M.colors.cterm0A, ctermbg = nil })

    hl('gitcommitUnmergedFile',
        { guifg = M.colors.base08, guibg = nil, gui = 'bold', guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('gitcommitDiscardedFile',
        { guifg = M.colors.base08, guibg = nil, gui = 'bold', guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('gitcommitSelectedFile',
        { guifg = M.colors.base0B, guibg = nil, gui = 'bold', guisp = nil, ctermfg = M.colors.cterm0B, ctermbg = nil })

    -- GitGutter highlighting
    hl('GitGutterAdd',
        {
            guifg = M.colors.base0B,
            guibg = M.colors.base00,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm0B,
            ctermbg =
                M.colors.cterm00
        })

    hl('GitGutterChange',
        {
            guifg = M.colors.base0D,
            guibg = M.colors.base00,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm0D,
            ctermbg =
                M.colors.cterm00
        })

    hl('GitGutterDelete',
        {
            guifg = M.colors.base08,
            guibg = M.colors.base00,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm08,
            ctermbg =
                M.colors.cterm00
        })

    hl('GitGutterChangeDelete',
        {
            guifg = M.colors.base0E,
            guibg = M.colors.base00,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm0E,
            ctermbg =
                M.colors.cterm00
        })

    -- Spelling highlighting
    hl('SpellBad', { guifg = nil, guibg = nil, gui = 'undercurl', guisp = M.colors.base08, ctermfg = nil, ctermbg = nil })

    hl('SpellLocal',
        { guifg = nil, guibg = nil, gui = 'undercurl', guisp = M.colors.base0C, ctermfg = nil, ctermbg = nil })

    hl('SpellCap', { guifg = nil, guibg = nil, gui = 'undercurl', guisp = M.colors.base0D, ctermfg = nil, ctermbg = nil })

    hl('SpellRare',
        { guifg = nil, guibg = nil, gui = 'undercurl', guisp = M.colors.base0E, ctermfg = nil, ctermbg = nil })

    -- Diagnostics
    hl('DiagnosticError',
        { guifg = M.colors.base08, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('DiagnosticWarn',
        { guifg = M.colors.base0A, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0E, ctermbg = nil })

    hl('DiagnosticInfo',
        { guifg = M.colors.base0D, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })

    hl('DiagnosticHint',
        { guifg = M.colors.base0C, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0C, ctermbg = nil })

    -- Diagnostic underlines
    hl('DiagnosticUnderlineError',
        { guifg = nil, guibg = nil, gui = 'undercurl', guisp = M.colors.base08, ctermfg = nil, ctermbg = nil })

    hl('DiagnosticUnderlineWarning',
        { guifg = nil, guibg = nil, gui = 'undercurl', guisp = M.colors.base0E, ctermfg = nil, ctermbg = nil })

    hl('DiagnosticUnderlineWarn',
        { guifg = nil, guibg = nil, gui = 'undercurl', guisp = M.colors.base0E, ctermfg = nil, ctermbg = nil })

    hl('DiagnosticUnderlineInformation',
        { guifg = nil, guibg = nil, gui = 'undercurl', guisp = M.colors.base0F, ctermfg = nil, ctermbg = nil })

    hl('DiagnosticUnderlineHint',
        { guifg = nil, guibg = nil, gui = 'undercurl', guisp = M.colors.base0C, ctermfg = nil, ctermbg = nil })

    -- LSP references
    hl('LspReferenceText',
        { guifg = nil, guibg = nil, gui = 'underline', guisp = M.colors.base04, ctermfg = nil, ctermbg = nil })

    hl('LspReferenceRead',
        { guifg = nil, guibg = nil, gui = 'underline', guisp = M.colors.base04, ctermfg = nil, ctermbg = nil })

    hl('LspReferenceWrite',
        { guifg = nil, guibg = nil, gui = 'underline', guisp = M.colors.base04, ctermfg = nil, ctermbg = nil })

    -- Tree-sitter
    hl('TSAnnotation',
        { guifg = M.colors.base0F, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0F, ctermbg = nil })

    hl('TSAttribute',
        { guifg = M.colors.base0A, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0A, ctermbg = nil })

    hl('TSBoolean',
        { guifg = M.colors.base09, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm09, ctermbg = nil })

    hl('TSCharacter',
        { guifg = M.colors.base08, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('TSComment',
        { guifg = M.colors.base03, guibg = nil, gui = 'italic', guisp = nil, ctermfg = M.colors.cterm03, ctermbg = nil })

    hl('TSConstructor',
        { guifg = M.colors.base0D, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })

    hl('TSConditional',
        { guifg = M.colors.base0E, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0E, ctermbg = nil })

    hl('TSConstant',
        { guifg = M.colors.base09, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm09, ctermbg = nil })

    hl('TSConstBuiltin',
        { guifg = M.colors.base09, guibg = nil, gui = 'italic', guisp = nil, ctermfg = M.colors.cterm09, ctermbg = nil })

    hl('TSConstMacro',
        { guifg = M.colors.base08, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('TSError',
        { guifg = M.colors.base08, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('TSException',
        { guifg = M.colors.base08, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('TSField',
        { guifg = M.colors.base05, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm05, ctermbg = nil })

    hl('TSFloat',
        { guifg = M.colors.base09, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm09, ctermbg = nil })

    hl('TSFunction',
        { guifg = M.colors.base0D, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })

    hl('TSFuncBuiltin',
        { guifg = M.colors.base0D, guibg = nil, gui = 'italic', guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })

    hl('TSFuncMacro',
        { guifg = M.colors.base08, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('TSInclude',
        { guifg = M.colors.base0D, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })

    hl('TSKeyword',
        { guifg = M.colors.base0E, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0E, ctermbg = nil })

    hl('TSKeywordFunction',
        { guifg = M.colors.base0E, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0E, ctermbg = nil })

    hl('TSKeywordOperator',
        { guifg = M.colors.base0E, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0E, ctermbg = nil })

    hl('TSLabel',
        { guifg = M.colors.base0A, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0A, ctermbg = nil })

    hl('TSMethod',
        { guifg = M.colors.base0D, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })

    hl('TSNamespace',
        { guifg = M.colors.base08, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('TSNone',
        { guifg = M.colors.base05, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm05, ctermbg = nil })

    hl('TSNumber',
        { guifg = M.colors.base09, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm09, ctermbg = nil })

    hl('TSOperator',
        { guifg = M.colors.base05, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm05, ctermbg = nil })

    hl('TSParameter',
        { guifg = M.colors.base05, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm05, ctermbg = nil })

    hl('TSParameterReference',
        { guifg = M.colors.base05, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm05, ctermbg = nil })

    hl('TSProperty',
        { guifg = M.colors.base05, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm05, ctermbg = nil })

    hl('TSPunctDelimiter',
        { guifg = M.colors.base0F, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0F, ctermbg = nil })

    hl('TSPunctBracket',
        { guifg = M.colors.base05, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm05, ctermbg = nil })

    hl('TSPunctSpecial',
        { guifg = M.colors.base0F, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0F, ctermbg = nil })

    hl('TSRepeat',
        { guifg = M.colors.base0E, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0E, ctermbg = nil })

    hl('TSString',
        { guifg = M.colors.base0B, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0B, ctermbg = nil })

    hl('TSStringRegex',
        { guifg = M.colors.base0C, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0C, ctermbg = nil })

    hl('TSStringEscape',
        { guifg = M.colors.base0C, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0C, ctermbg = nil })

    hl('TSSymbol',
        { guifg = M.colors.base0B, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0B, ctermbg = nil })

    hl('TSTag',
        { guifg = M.colors.base08, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('TSTagDelimiter',
        { guifg = M.colors.base0F, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0F, ctermbg = nil })

    hl('TSText',
        { guifg = M.colors.base05, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm05, ctermbg = nil })

    -- Tree-sitter (continued: text / markup)
    hl('TSStrong', { guifg = nil, guibg = nil, gui = 'bold', guisp = nil, ctermfg = nil, ctermbg = nil })

    hl('TSEmphasis',
        { guifg = M.colors.base09, guibg = nil, gui = 'italic', guisp = nil, ctermfg = M.colors.cterm09, ctermbg = nil })

    hl('TSUnderline',
        { guifg = M.colors.base00, guibg = nil, gui = 'underline', guisp = nil, ctermfg = M.colors.cterm00, ctermbg = nil })

    hl('TSStrike',
        { guifg = M.colors.base00, guibg = nil, gui = 'strikethrough', guisp = nil, ctermfg = M.colors.cterm00, ctermbg = nil })

    hl('TSTitle',
        { guifg = M.colors.base0D, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })

    hl('TSLiteral',
        { guifg = M.colors.base09, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm09, ctermbg = nil })

    hl('TSURI',
        { guifg = M.colors.base09, guibg = nil, gui = 'underline', guisp = nil, ctermfg = M.colors.cterm09, ctermbg = nil })

    hl('TSType',
        { guifg = M.colors.base0A, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0A, ctermbg = nil })

    hl('TSTypeBuiltin',
        { guifg = M.colors.base0A, guibg = nil, gui = 'italic', guisp = nil, ctermfg = M.colors.cterm0A, ctermbg = nil })

    hl('TSVariable',
        { guifg = M.colors.base08, guibg = nil, gui = 'none', guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('TSVariableBuiltin',
        { guifg = M.colors.base08, guibg = nil, gui = 'italic', guisp = nil, ctermfg = M.colors.cterm08, ctermbg = nil })

    hl('TSDefinition',
        { guifg = nil, guibg = nil, gui = 'underline', guisp = M.colors.base04, ctermfg = nil, ctermbg = nil })

    hl('TSDefinitionUsage',
        { guifg = nil, guibg = nil, gui = 'underline', guisp = M.colors.base04, ctermfg = nil, ctermbg = nil })

    hl('TSCurrentScope', { guifg = nil, guibg = nil, gui = 'bold', guisp = nil, ctermfg = nil, ctermbg = nil })

    -- LSP inlay hints
    -- hl('LspInlayHint',
    --     { guifg = M.colors.base03, guibg = nil, gui = 'italic', guisp = nil, ctermfg = M.colors.cterm03, ctermbg = nil })

    hl('NvimInternalError',
        {
            guifg = M.colors.base00,
            guibg = M.colors.base08,
            gui = 'none',
            guisp = nil,
            ctermfg = M.colors.cterm00,
            ctermbg =
                M.colors.cterm08
        })

    hl('NormalFloat',
        {
            guifg = M.colors.base05,
            guibg = M.colors.base01,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm05,
            ctermbg =
                M.colors.cterm00
        })

    hl('FloatBorder',
        {
            guifg = M.colors.base05,
            guibg = M.colors.base01,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm05,
            ctermbg =
                M.colors.cterm00
        })

    hl('FloatTitle',
        { guifg = M.colors.base0D, guibg = M.colors.base01, gui = 'none', guisp = nil, ctermfg = M.colors.cterm0D, ctermbg = nil })


    hl('NormalNC',
        {
            guifg = M.colors.base05,
            guibg = M.colors.base00,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm05,
            ctermbg =
                M.colors.cterm00
        })

    hl('TermCursor',
        {
            guifg = M.colors.base00,
            guibg = M.colors.base05,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm00,
            ctermbg =
                M.colors.cterm05
        })

    hl('TermCursorNC',
        {
            guifg = M.colors.base00,
            guibg = M.colors.base05,
            gui = nil,
            guisp = nil,
            ctermfg = M.colors.cterm00,
            ctermbg =
                M.colors.cterm05
        })


    if M.config.which_key then
        hl('WhichKey', { guifg = M.colors.base0D, guibg = nil, gui = nil, guisp = nil, ctermfg = nil, ctermbg = nil, })

        hl('WhichKeyDesc',
            { guifg = M.colors.base05, guibg = nil, gui = nil, guisp = nil, ctermfg = nil, ctermbg = nil, })

        hl('WhichKeyFloat',
            {
                guifg = M.colors.base05,
                guibg = M.colors.base01,
                gui = nil,
                guisp = nil,
                ctermfg = nil,
                ctermbg = M
                    .colors.cterm01,
            })

        hl('WhichKeyGroup',
            { guifg = M.colors.base0E, guibg = nil, gui = nil, guisp = nil, ctermfg = nil, ctermbg = nil, })

        hl('WhichKeySeparator',
            { guifg = M.colors.base0B, guibg = nil, gui = nil, guisp = nil, ctermfg = nil, ctermbg = M.colors.cterm01, })

        hl('WhichKeyValue',
            { guifg = M.colors.base03, guibg = nil, gui = nil, guisp = nil, ctermfg = nil, ctermbg = nil, })
    end


    if M.config.mini_completion then
        hl('MiniCompletionActiveParameter', 'CursorLine')
    end

    vim.g.terminal_color_0  = M.colors.base00
    vim.g.terminal_color_1  = M.colors.base08
    vim.g.terminal_color_2  = M.colors.base0B
    vim.g.terminal_color_3  = M.colors.base0A
    vim.g.terminal_color_4  = M.colors.base0D
    vim.g.terminal_color_5  = M.colors.base0E
    vim.g.terminal_color_6  = M.colors.base0C
    vim.g.terminal_color_7  = M.colors.base05
    vim.g.terminal_color_8  = M.colors.base03
    vim.g.terminal_color_9  = M.colors.base08
    vim.g.terminal_color_10 = M.colors.base0B
    vim.g.terminal_color_11 = M.colors.base0A
    vim.g.terminal_color_12 = M.colors.base0D
    vim.g.terminal_color_13 = M.colors.base0E
    vim.g.terminal_color_14 = M.colors.base0C
    vim.g.terminal_color_15 = M.colors.base07

    vim.g.base16_gui00      = M.colors.base00
    vim.g.base16_gui01      = M.colors.base01
    vim.g.base16_gui02      = M.colors.base02
    vim.g.base16_gui03      = M.colors.base03
    vim.g.base16_gui04      = M.colors.base04
    vim.g.base16_gui05      = M.colors.base05
    vim.g.base16_gui06      = M.colors.base06
    vim.g.base16_gui07      = M.colors.base07
    vim.g.base16_gui08      = M.colors.base08
    vim.g.base16_gui09      = M.colors.base09
    vim.g.base16_gui0A      = M.colors.base0A
    vim.g.base16_gui0B      = M.colors.base0B
    vim.g.base16_gui0C      = M.colors.base0C
    vim.g.base16_gui0D      = M.colors.base0D
    vim.g.base16_gui0E      = M.colors.base0E
    vim.g.base16_gui0F      = M.colors.base0F
end

return M
