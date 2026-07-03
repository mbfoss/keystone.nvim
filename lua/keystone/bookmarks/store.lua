local M = {}

local fsutil = require("keystone.tk.fsutil")

---@param config keystone.bookmarks.Config
---@return string
local function _resolve_dir(config)
    local pd = config.persist_dir
    if type(pd) == "function" then
        return pd()
    elseif type(pd) == "string" and pd ~= "" then
        return pd
    end
    return vim.fn.stdpath("data")
end

---@param config keystone.bookmarks.Config
---@return string
function M.filepath(config)
    return vim.fs.joinpath(_resolve_dir(config), "keystone_bookmarks.json")
end

---@param file string
---@param lnum integer
---@return string
local function _loc_key(file, lnum)
    return file .. "\0" .. lnum
end

-- Loc-keys this instance owns: the set we last loaded or wrote. A disk entry at
-- a key outside this set belongs to another instance and is preserved on save;
-- a disk entry inside it is dictated solely by our live set, so a bookmark we
-- deleted (or that moved to a new line) is not merged back at its old location.
---@type table<string, true>
local _baseline = {}

---@param config keystone.bookmarks.Config
---@return keystone.bookmarks.Entry[]
local function _read_file(config)
    local ok, raw = fsutil.read_content(M.filepath(config))
    if not ok or raw == "" then return {} end
    local parsed_ok, data = pcall(vim.json.decode, raw)
    if not parsed_ok or type(data) ~= "table" then return {} end
    local result = {}
    for _, e in ipairs(data) do
        if type(e) == "table"
            and type(e.file) == "string" and e.file ~= ""
            and type(e.lnum) == "number"
        then
            -- `name` is the pre-relabel field; fall back to it so existing stores migrate in place.
            local label = e.label or e.name
            if type(label) ~= "string" or label == "" then label = nil end
            table.insert(result, { file = e.file, lnum = e.lnum, label = label })
        end
    end
    return result
end

-- Reads bookmarks from disk and records them as this instance's baseline (the
-- caller is expected to materialize an extmark for each, making them our live set).
---@param config keystone.bookmarks.Config
---@return keystone.bookmarks.Entry[]
function M.load(config)
    local entries = _read_file(config)
    _baseline = {}
    for _, e in ipairs(entries) do
        _baseline[_loc_key(e.file, e.lnum)] = true
    end
    return entries
end

-- Persists `entries` (the authoritative live snapshot) atomically via a
-- PID-unique temp file + rename. Disk entries at keys outside our baseline are
-- other instances' bookmarks and are merged in; the baseline is then reset to
-- exactly the entries we own.
---@param entries keystone.bookmarks.Entry[]
---@param config keystone.bookmarks.Config
function M.save(entries, config)
    local path = M.filepath(config)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

    ---@type table<string, keystone.bookmarks.Entry>
    local keep = {}
    for _, e in ipairs(entries) do
        keep[_loc_key(e.file, e.lnum)] = { file = e.file, lnum = e.lnum, label = e.label }
    end

    for _, e in ipairs(_read_file(config)) do
        local key = _loc_key(e.file, e.lnum)
        if not keep[key] and not _baseline[key] then
            keep[key] = e
        end
    end

    local ok, encoded = pcall(vim.json.encode, vim.tbl_values(keep))
    if not ok then return end

    local tmp = string.format("%s.%s.tmp", path, vim.uv.os_getpid())
    if not fsutil.write_content(tmp, encoded) then return end
    os.rename(tmp, path)

    -- Only our own entries form the next baseline; merged foreign entries stay
    -- foreign so they keep being preserved on subsequent saves.
    _baseline = {}
    for _, e in ipairs(entries) do
        _baseline[_loc_key(e.file, e.lnum)] = true
    end
end

return M
