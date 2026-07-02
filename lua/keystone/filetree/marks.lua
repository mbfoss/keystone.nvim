--- Persistent, letter-keyed bookmarks for the file tree (files or
--- directories), overriding vim's standard `m` / `'` mark mappings within
--- the tree buffer.
local M = {}

local fsutil = require("keystone.tk.fsutil")

---@type table<string, string> mark char -> absolute path
local _marks = {}

local _loaded = false
---@type string?
local _persist_file

---@return string
local function _filepath()
    return _persist_file or vim.fs.joinpath(vim.fn.stdpath("data"), "keystone.ftmarks.json")
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
end

local function _save()
    local path = _filepath()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local ok, encoded = pcall(vim.json.encode, _marks)
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
function M.set(char, path)
    if not _loaded then _load() end
    _marks[char] = vim.fs.normalize(path)
    _save()
end

---@param char string
---@return string?
function M.get(char)
    if not _loaded then _load() end
    return _marks[char]
end

---@param char string
function M.delete(char)
    if not _loaded then _load() end
    if _marks[char] then
        _marks[char] = nil
        _save()
    end
end

---@return table<string, string>
function M.get_all()
    if not _loaded then _load() end
    return _marks
end

return M
