local M = {}

local throttle = require("keystone.util.throttle")

-- ---------------------------------------------------------------------------
-- Mark signs
--
-- Draws the name of every mark that is set (`ma`, `mA`, ...) in the sign column
-- of the line holding it, so the marks in a buffer are visible without `:marks`.
--
-- Neovim 0.12's `MarkSet` event does the work that used to need polling: it
-- fires after a mark is set by `m`, `:mark` or `nvim_buf_set_mark()`, and after
-- one is deleted by `:delmarks` or `nvim_buf_del_mark()` -- a deletion reports
-- `line == 0`. The event data names the mark, so an explicit change costs one
-- recompute of the buffer that owns it. Without the event the module stays
-- inert, so it needs Neovim >= 0.12 while the rest of keystone needs 0.11.
--
-- One change stays invisible to `MarkSet`: deleting the line a mark sits on
-- drops the mark silently. `TextChanged`/`InsertLeave` catch that. They say
-- nothing about *which* marks moved, so they queue a debounced whole-buffer
-- recompute -- cheap, since a buffer holds at most 52 signable marks.
--
-- Signs are extmarks in a private namespace rather than `sign_place()`: they
-- ride along with edits, and the namespace can be cleared per buffer.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

local _HL_LOCAL = "KeystoneMarkSignsLocal"
local _HL_GLOBAL = "KeystoneMarkSignsGlobal"

vim.api.nvim_set_hl(0, _HL_LOCAL, { default = true, link = "DiagnosticHint" })
vim.api.nvim_set_hl(0, _HL_GLOBAL, { default = true, link = "DiagnosticInfo" })

---@class keystone.marksigns.Config
---@field enabled boolean? master switch; when false no signs are placed
---@field marks string? mark names to sign, most significant first
---@field combine boolean? show two names in one sign when a line holds several marks
---@field hl_local string? highlight group for `a-z` (buffer-local) marks
---@field hl_global string? highlight group for `A-Z` (file) marks
---@field sign_priority integer? sign priority, weighed against other plugins' signs

---@return keystone.marksigns.Config
local function _get_default_config()
    ---@type keystone.marksigns.Config
    return {
        enabled       = true,
        marks         = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
        combine       = true,
        hl_local      = _HL_LOCAL,
        hl_global     = _HL_GLOBAL,
        sign_priority = 5,
    }
end

---@type keystone.marksigns.Config
M.config = _get_default_config()

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local _NS = vim.api.nvim_create_namespace("keystone.marksigns")
local _AUGROUP = "keystone.marksigns"

-- `TextChanged`/`InsertLeave` only report "something changed", so the recompute
-- they queue is coalesced: a burst of edits costs one pass, this long after the
-- first of them.
local _REFRESH_MS = 120

local _enabled = false

-- Signable mark names mapped to their position in `config.marks`, which orders
-- the names that share a line. Membership doubles as the filter: `MarkSet` also
-- fires for marks like `.` and `"`, which have no name worth showing.
---@type table<string, integer>
local _ranks = {}

-- Buffers awaiting the debounced recompute.
---@type table<integer, true>
local _dirty = {}

-- ---------------------------------------------------------------------------
-- Marks
-- ---------------------------------------------------------------------------

--- True for the `A-Z` marks, which belong to a file rather than a buffer.
---@param name string
---@return boolean
local function _is_global(name)
    return name:match("^%u$") ~= nil
end

--- Whether `bufnr` can carry mark signs. Special buffers (trees, terminals,
--- prompts) are skipped: marks in them are not something to navigate back to.
---@param bufnr integer
---@return boolean
local function _is_signable(bufnr)
    return vim.api.nvim_buf_is_valid(bufnr)
        and vim.api.nvim_buf_is_loaded(bufnr)
        and vim.bo[bufnr].buftype == ""
end

--- Every signable mark in `bufnr`, grouped by the line it sits on and ordered
--- within a line by `config.marks`. Lines past the end of the buffer -- a stale
--- file mark from a shada file that outlived the text -- are clamped to the last
--- line, which is where jumping to the mark lands.
---@param bufnr integer
---@return table<integer, string[]>  1-based line -> mark names
local function _collect(bufnr)
    local line_count = vim.api.nvim_buf_line_count(bufnr)

    ---@type table<integer, string[]>
    local by_line = {}

    ---@param name string
    ---@param lnum integer
    local function add(name, lnum)
        if not _ranks[name] or lnum < 1 then return end
        lnum = math.min(lnum, line_count)

        local names = by_line[lnum]
        if names then
            names[#names + 1] = name
        else
            by_line[lnum] = { name }
        end
    end

    for _, mark in ipairs(vim.fn.getmarklist(bufnr)) do
        add(mark.mark:sub(2), mark.pos[2])
    end

    -- File marks are listed globally, each with the file it points at; the ones
    -- for this buffer are found by path, since the buffer number a file mark
    -- carries goes stale once its buffer is unloaded.
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file ~= "" then
        file = vim.fn.fnamemodify(file, ":p")
        for _, mark in ipairs(vim.fn.getmarklist()) do
            if mark.file and vim.fn.fnamemodify(mark.file, ":p") == file then
                add(mark.mark:sub(2), mark.pos[2])
            end
        end
    end

    for _, names in pairs(by_line) do
        table.sort(names, function(a, b) return _ranks[a] < _ranks[b] end)
    end

    return by_line
end

--- The sign for one line's marks. The sign column is two cells wide, so a second
--- mark can share it; any beyond that are represented by the first two. The
--- highlight follows the most significant mark.
---@param names string[]  ordered by `config.marks`
---@return string text, string hl
local function _sign(names)
    local config = M.config
    local text = names[1]
    if config.combine and names[2] then
        text = names[1] .. names[2]
    end
    return text, _is_global(names[1]) and config.hl_global or config.hl_local
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Recompute every sign in `bufnr` from scratch. Always clears first, so it also
--- undoes signs for marks that have since gone away.
---@param bufnr integer
local function _refresh(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    vim.api.nvim_buf_clear_namespace(bufnr, _NS, 0, -1)
    if not _enabled or not _is_signable(bufnr) then return end

    local priority = M.config.sign_priority

    for lnum, names in pairs(_collect(bufnr)) do
        local text, hl = _sign(names)
        vim.api.nvim_buf_set_extmark(bufnr, _NS, lnum - 1, 0, {
            sign_text     = text,
            sign_hl_group = hl,
            priority      = priority,
        })
    end
end

local function _refresh_all()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            _refresh(bufnr)
        end
    end
end

local _flush = throttle.trailing_fixed_wrap(_REFRESH_MS, function()
    local buffers = _dirty
    _dirty = {}

    if not _enabled then return end
    for bufnr in pairs(buffers) do
        _refresh(bufnr)
    end
end)

---@param bufnr integer
local function _queue(bufnr)
    _dirty[bufnr] = true
    _flush()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Recompute the signs of `bufnr` (defaults to the current buffer) now.
---@param bufnr integer?
function M.refresh(bufnr)
    _refresh(bufnr or vim.api.nvim_get_current_buf())
end

--- Whether signs are being drawn.
---@return boolean
function M.is_enabled()
    return _enabled
end

--- Start drawing mark signs. A no-op, with a warning, on a Neovim without the
--- `MarkSet` event.
function M.enable()
    if vim.fn.exists("##MarkSet") ~= 1 then
        vim.notify(
            "keystone.marksigns: requires Neovim >= 0.12 (the MarkSet event)",
            vim.log.levels.WARN
        )
        return
    end

    _enabled = true

    _ranks = {}
    for i = 1, #M.config.marks do
        _ranks[M.config.marks:sub(i, i)] = i
    end

    local group = vim.api.nvim_create_augroup(_AUGROUP, { clear = true })

    vim.api.nvim_create_autocmd("MarkSet", {
        group = group,
        -- The pattern is matched against the mark name; `_ranks` does the
        -- filtering instead, so a custom `config.marks` needs no new autocmd.
        pattern = "*",
        callback = function(ev)
            local name = ev.data.name
            if not _ranks[name] then return end

            if _is_global(name) then
                -- A file mark moves between buffers, and the buffer that used to
                -- hold it gets no event of its own, so all of them are redone.
                _refresh_all()
            else
                _refresh(ev.buf)
            end
        end,
    })

    -- Marks restored from shada are in place by the time the read finishes.
    vim.api.nvim_create_autocmd("BufReadPost", {
        group = group,
        callback = function(ev) _refresh(ev.buf) end,
    })

    -- Deleting the line under a mark drops the mark without a `MarkSet`.
    vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
        group = group,
        callback = function(ev) _queue(ev.buf) end,
    })

    _refresh_all()
end

--- Stop drawing mark signs and remove the ones already placed.
function M.disable()
    _enabled = false
    _dirty = {}

    -- `clear` empties the group whether or not it exists yet, which `del` cannot.
    vim.api.nvim_create_augroup(_AUGROUP, { clear = true })

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_clear_namespace(bufnr, _NS, 0, -1)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

---@param opts keystone.marksigns.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

    M.disable()
    if M.config.enabled then
        M.enable()
    end
end

return M
