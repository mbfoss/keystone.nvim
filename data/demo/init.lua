-- Minimal, self-contained init for the README recordings.
local demo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(demo .. "/../..", ":p")

vim.opt.rtp:append(demo) -- data/demo/colors/pastelstone.lua
vim.opt.rtp:append(root) -- the plugin itself

vim.o.number = true
vim.o.relativenumber = true
vim.o.cursorline = true
vim.o.signcolumn = "no"
vim.o.wrap = false
vim.o.scrolloff = 8
vim.o.showtabline = 2
vim.o.laststatus = 2
vim.o.cmdheight = 1
vim.o.termguicolors = true
vim.o.background = "dark"
vim.o.mouse = ""
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.undofile = false
vim.o.backup = false
vim.o.list = false
vim.o.shortmess = vim.o.shortmess .. "I"
vim.opt.clipboard = ""
vim.g.mapleader = " "

vim.cmd("colorscheme pastelstone")

-- Statusline: the project on the left, the open file on the right.
vim.api.nvim_set_hl(0, "DemoStatusLeft", { fg = "#2e2f33", bg = "#90b8e3", bold = true })
vim.api.nvim_set_hl(0, "DemoStatusRight", { fg = "#dcdce4", bg = "#46474f" })
vim.o.statusline = "%#DemoStatusLeft# keystone.nvim %#DemoStatusRight#%= %F "

require("nvim_demo").setup({ fg = "#2e2f33", bg = "#90b8e3", fill = "#3a3b41" })

-- The two modules the scenes record. Slower than the defaults so the
-- interpolation is visible in a 20 fps recording.
require("keystone.animate").setup({ speed = 40, duration = 600 })
require("keystone.select").setup()

-- Scenes that show the follow-up-key popup opt in with KS_DEMO_CLUE.
if vim.env.KS_DEMO_CLUE and vim.env.KS_DEMO_CLUE ~= "" then
    require("keystone.clue").setup()
end

-- A scene that wants a file on screen names it here, so the recording starts
-- on the buffer instead of an `:edit` command left behind on the command line.
if vim.env.KS_DEMO_FILE and vim.env.KS_DEMO_FILE ~= "" then
    vim.cmd.edit(vim.fn.fnameescape(root .. vim.env.KS_DEMO_FILE))
end

-- `:DemoFiles` stands in for any `vim.ui.select` caller: it lists the plugin's
-- Lua files and previews each one through `preview_item`.
local function demo_files()
    local files = vim.fn.globpath(root .. "lua", "**/*.lua", false, true)
    table.sort(files)

    local items = {}
    for _, path in ipairs(files) do
        items[#items + 1] = { name = path:sub(#root + 1), path = path }
    end

    local preview = vim.api.nvim_create_buf(false, true)
    vim.bo[preview].bufhidden = "hide"

    vim.ui.select(items, {
        prompt = "Select a file",
        format_item = function(item) return item.name end,
        preview_item = function(item)
            vim.bo[preview].modifiable = true
            vim.api.nvim_buf_set_lines(preview, 0, -1, false, vim.fn.readfile(item.path))
            vim.bo[preview].modifiable = false
            vim.bo[preview].filetype = "lua"
            return { buf = preview, pos = { 1, 0 } }
        end,
    }, function(item)
        if vim.api.nvim_buf_is_valid(preview) then
            vim.api.nvim_buf_delete(preview, { force = true })
        end
        if item then vim.cmd.edit(vim.fn.fnameescape(item.path)) end
    end)
end

vim.api.nvim_create_user_command("DemoFiles", demo_files, {})
