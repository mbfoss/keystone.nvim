--- Persistent, letter-keyed bookmarks for the file tree (files or
--- directories), overriding vim's standard `m` / `'` mark mappings within
--- the tree buffer.
local M = {}

local fsutil = require("keystone.tk.fsutil")

---@type table<string, string> mark char -> absolute path
local _marks = {}
---@type table<string, string> absolute path -> mark char (reverse index of _marks)
local _by_path = {}

local _loaded = false
---@type string?
local _persist_file

---@return string
local function _filepath()
    return _persist_file or vim.fs.joinpath(vim.fn.stdpath("data"), "keystone.ftmarks.json")
end

--- Rebuild the path -> char reverse index from _marks. When several chars point
--- at the same path the last one seen wins, which is all the tree display needs.
local function _rebuild_index()
    _by_path = {}
    for char, path in pairs(_marks) do
        _by_path[path] = char
    end
end

local function _load()
    _loaded = true
    local ok, raw = fsutil.read_content(_filepath())
    if not ok or raw == "" then return end
    local parsed_ok, data = pcall(vim.json.decode, raw)
    if not parsed_ok or type(data) ~= "table" then return end
    for char, path in pairs(data) do
        if type(char) == "string" and type(path) == "string" then
            _marks[char] = path
        end
    end
    _rebuild_index()
end

local function _save()
    local path = _filepath()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    -- An empty Lua table encodes as a JSON array ("[]"); force an object so the
    -- file always round-trips back to a char -> path map.
    local ok, encoded = pcall(vim.json.encode, next(_marks) and _marks or vim.empty_dict())
    if not ok then return end
    local tmp = string.format("%s.%s.tmp", path, vim.uv.os_getpid())
    if not fsutil.write_content(tmp, encoded) then return end
    os.rename(tmp, path)
end

---@param persist_file (string | fun():string)?
function M.setup(persist_file)
    if type(persist_file) == "function" then
        _persist_file = persist_file()
    else
        _persist_file = persist_file
    end
    _load()
end

---@param char string
---@param path string
---@return string? prev_path the path this char pointed at before, if any
function M.set(char, path)
    if not _loaded then _load() end
    path = vim.fs.normalize(path)
    local prev = _marks[char]
    -- Only one bookmark char per path: drop whatever char already points here so
    -- the new char overrides it.
    local old_char = _by_path[path]
    if old_char and old_char ~= char then
        _marks[old_char] = nil
    end
    _marks[char] = path
    _rebuild_index()
    _save()
    return prev
end

---@param char string
---@return string?
function M.get(char)
    if not _loaded then _load() end
    return _marks[char]
end

--- The mark char bound to `path`, if any (reverse of `M.get`).
---@param path string
---@return string?
function M.path_char(path)
    if not _loaded then _load() end
    return _by_path[vim.fs.normalize(path)]
end

---@param char string
function M.delete(char)
    if not _loaded then _load() end
    if _marks[char] then
        _marks[char] = nil
        _rebuild_index()
        _save()
    end
end

---@return table<string, string>
function M.get_all()
    if not _loaded then _load() end
    return _marks
end

return M
