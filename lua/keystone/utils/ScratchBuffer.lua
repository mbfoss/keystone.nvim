local class = require('keystone.utils.class')
local Trackers = require('keystone.utils.Trackers')

---@class keystone.KeyMap
---@field callback fun()
---@field desc string
---@
---@alias keystone.Keymaps table<string,keystone.KeyMap>

---@class keystone.Tracker
---@field on_create fun()?
---@field on_loaded fun()?
---@field on_change fun()?
---@field on_delete fun()?

---@class keystone.ScratchBuffer.Opts
---@field bo vim.bo?

---@class keystone.ScratchBuffer
---@field new fun(self: keystone.ScratchBuffer, opts:keystone.ScratchBuffer.Opts): keystone.ScratchBuffer
local ScratchBuffer = class()

---@param opts keystone.ScratchBuffer.Opts
function ScratchBuffer:init(opts)
    vim.validate("opts", opts, "table")
    self._bo = vim.deepcopy(opts.bo or {})
    self._buf = -1

    self._trackers = Trackers:new()
end

function ScratchBuffer:delete()
    if self._buf > 0 then
        if vim.v.exiting == vim.NIL then
            vim.api.nvim_buf_delete(self._buf, { force = true })
        end
    end
end

---@param callbacks keystone.Tracker>
---@return keystone.TrackerRef
function ScratchBuffer:add_tracker(callbacks)
    return self._trackers:add_tracker(callbacks)
end

---@return boolean
function ScratchBuffer:create()
    if vim.v.exiting ~= vim.NIL then return false end
    if self._buf ~= -1 then
        if not vim.api.nvim_buf_is_loaded(self._buf) then
            vim.fn.bufload(self._buf)
        end
        return true
    end
    local listed = self._bo.buflisted
    if listed == nil then listed = true end
    self._buf = vim.api.nvim_create_buf(listed, true)
    self._trackers:invoke("on_create")
    self:_on_loaded()
    return true
end

---@return number -- buffer number
function ScratchBuffer:get_bufnr()
    return self._buf
end

---@private
function ScratchBuffer:_on_loaded()
    assert(self._buf > 0)

    local buf = self._buf
    for k, v in pairs(self._bo) do
        vim.bo[buf][k] = v
    end

    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        buffer = buf,
        once = true,
        callback = function(ev)
            assert(ev.buf == buf)
            self._buf = -1
            self._trackers:invoke("on_delete")
        end,
    })

    self._trackers:invoke("on_loaded")
end

---@param mode string|string[]
---@param key string
---@param rhs string|function
---@param opts vim.keymap.set.Opts?
function ScratchBuffer:set_keymap(mode, key, rhs, opts)
    if self._buf ~= -1 then
        opts = opts or {}
        opts.buffer = self._buf
        pcall(function() vim.keymap.del(mode, key, { buffer = self._buf }) end)
        vim.keymap.set(mode, key, rhs, opts)
    end
end

return ScratchBuffer
