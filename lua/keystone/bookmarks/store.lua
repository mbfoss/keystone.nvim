local M = {}

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
    return _resolve_dir(config) .. "/keystone_bookmarks.json"
end

---@param config keystone.bookmarks.Config
---@return keystone.bookmarks.Entry[]
function M.load(config)
    local path = M.filepath(config)
    local f = io.open(path, "r")
    if not f then return {} end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then return {} end
    local ok, data = pcall(vim.json.decode, raw)
    if not ok or type(data) ~= "table" then return {} end
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

---@param config keystone.bookmarks.Config
---@param entries keystone.bookmarks.Entry[]
function M.save(config, entries)
    local path = M.filepath(config)
    local dir = vim.fn.fnamemodify(path, ":h")
    vim.fn.mkdir(dir, "p")
    local ok, encoded = pcall(vim.json.encode, entries)
    if not ok then return end
    -- Write to a PID-unique temp file then rename atomically to avoid
    -- partial writes being visible to other instances reading concurrently.
    local tmp = string.format("%s.%s.tmp", path, vim.uv.os_getpid())
    local f = io.open(tmp, "w")
    if not f then return end
    f:write(encoded)
    f:close()
    os.rename(tmp, path)
end

return M
