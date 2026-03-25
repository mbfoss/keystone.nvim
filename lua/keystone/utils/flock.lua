local ffi = require("ffi")
local bit = require("bit")

if ffi.os == "Windows" then
    ffi.cdef [[
        typedef void* HANDLE;
        typedef uint32_t DWORD;
        typedef struct _OVERLAPPED {
            uintptr_t Internal; uintptr_t InternalHigh;
            union { struct { DWORD Offset; DWORD OffsetHigh; }; void* Pointer; };
            HANDLE hEvent;
        } OVERLAPPED;

        int LockFileEx(HANDLE hFile, DWORD dwFlags, DWORD dwRes, DWORD nLow, DWORD nHigh, OVERLAPPED* lpOver);
        int UnlockFileEx(HANDLE hFile, DWORD dwRes, DWORD nLow, DWORD nHigh, OVERLAPPED* lpOver);
        HANDLE _get_osfhandle(int fd);
        int _fileno(struct FILE* stream);
    ]]
else
    ffi.cdef [[
        int flock(int fd, int operation);
        int fileno(struct FILE* stream);
    ]]
end

local M = {}
local _LOCKS = {} -- Registry of ACTIVE locks only

-- Constants
local LOCK_EX = 2
local LOCK_NB = 4
local LOCK_UN = 8
local WIN_LOCK_EX = 0x00000002
local WIN_LOCK_NB = 0x00000001

local function _normalize(path)
    return vim.fn.fnamemodify(path, ":p")
end

local function get_fd(file)
    local c_file = ffi.cast("struct FILE*", file)
    return ffi.os == "Windows" and ffi.C._fileno(c_file) or ffi.C.fileno(c_file)
end

---@param path string
---@return boolean,string?
function M.lock(path)
    local abs_path = _normalize(path)
    if _LOCKS[abs_path] then return false, "already locked" end

    local file, err = io.open(abs_path, "w")
    if not file then return false, err or "failed to open lock file" end

    local fd = get_fd(file)
    local success = false

    if ffi.os == "Windows" then
        local handle = ffi.C._get_osfhandle(fd)
        local overlapped = ffi.new("OVERLAPPED", { 0 })
        success = (ffi.C.LockFileEx(handle, bit.bor(WIN_LOCK_EX, WIN_LOCK_NB), 0, 1, 0, overlapped) ~= 0)
    else
        success = (ffi.C.flock(fd, bit.bor(LOCK_EX, LOCK_NB)) == 0)
    end

    if success then
        -- Only store in the registry if the lock was actually acquired
        _LOCKS[abs_path] = file
        file:write(tostring(vim.fn.getpid()))
        file:flush()
        return true
    else
        -- If lock fails, close the handle immediately and do NOT add to _LOCKS
        file:close()
        return false, nil
    end
end

function M.unlock(path)
    local abs_path = _normalize(path)
    local file = _LOCKS[abs_path]

    -- If it's not in our registry, there's nothing for us to unlock/close
    if not file then return false end

    -- Verify handle is still alive before FFI calls
    if io.type(file) == "file" then
        local fd = get_fd(file)
        if ffi.os == "Windows" then
            local handle = ffi.C._get_osfhandle(fd)
            local overlapped = ffi.new("OVERLAPPED", { 0 })
            ffi.C.UnlockFileEx(handle, 0, 1, 0, overlapped)
        else
            ffi.C.flock(fd, LOCK_UN)
        end
        file:close()
    end

    _LOCKS[abs_path] = nil
    pcall(os.remove, abs_path)
    return true
end

return M
