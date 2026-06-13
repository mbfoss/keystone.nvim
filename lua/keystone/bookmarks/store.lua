local M = {}

local fsutil = require("keystone.util.fsutil")

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

---@type table<string, keystone.bookmarks.Entry>
local _entries = {}

-- Locations explicitly deleted by this instance; excluded when merging disk extras.
---@type table<string, true>
local _deleted_locs = {}

-- ── Item operations ───────────────────────────────────────────────────────────

---@param entry keystone.bookmarks.Entry
function M.add(entry)
    local key = _loc_key(entry.file, entry.lnum)
    _entries[key] = entry
    _deleted_locs[key] = nil
end

---@param file string
---@param lnum integer
function M.delete(file, lnum)
    local key = _loc_key(file, lnum)
    _entries[key] = nil
    _deleted_locs[key] = true
end

-- ── Persistence ───────────────────────────────────────────────────────────────

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
            and type(e.name) == "string" and e.name ~= ""
            and type(e.file) == "string" and e.file ~= ""
            and type(e.lnum) == "number"
        then
            table.insert(result, { name = e.name, file = e.file, lnum = e.lnum })
        end
    end
    return result
end

-- Reads bookmarks from disk and registers each entry via M.add.
---@param config keystone.bookmarks.Config
---@return keystone.bookmarks.Entry[]
function M.load(config)
    for _, e in ipairs(_read_file(config)) do
        M.add(e)
    end
    return vim.tbl_values(_entries)
end

-- Merges _entries with locations on disk absent from _entries and not in
-- _deleted_locs, then writes atomically via a PID-unique temp file + rename.
---@param config keystone.bookmarks.Config
function M.save(config)
    local path = M.filepath(config)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

    local merged = vim.tbl_deep_extend("force", {}, _entries)
    for _, e in ipairs(_read_file(config)) do
        local key = _loc_key(e.file, e.lnum)
        if not _entries[key] and not _deleted_locs[key] then
            merged[key] = e
        end
    end

    local ok, encoded = pcall(vim.json.encode, vim.tbl_values(merged))
    if not ok then return end
    local tmp = string.format("%s.%s.tmp", path, vim.uv.os_getpid())
    local write_ok = fsutil.write_content(tmp, encoded)
    if not write_ok then return end
    os.rename(tmp, path)
end

return M
