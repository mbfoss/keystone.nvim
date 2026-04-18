local class = require('keystone.utils.class')
local Trackers = require('keystone.utils.Trackers')

---@class keystone.KeyMap
---@field callback fun()
---@field desc string
---@
---@alias keystone.Keymaps table<string,keystone.KeyMap>

---@class keystone.Tracker
---@field on_create fun()?
---@field on_change fun()?
---@field on_delete fun()?

---@class keystone.BufferOpts
---@field bo vim.bo?

---@class keystone.Buffer
---@field new fun(self: keystone.Buffer, opts:keystone.BufferOpts): keystone.Buffer
local Buffer = class()

---@param opts keystone.BufferOpts
function Buffer:init(opts)
    vim.validate("opts", opts, "table")
    self._bo = vim.deepcopy(opts.bo or {})
    self._keymaps = {}
    self._buf = -1

    self._trackers = Trackers:new()
end

function Buffer:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    if self._buf > 0 then
        if vim.v.exiting == vim.NIL then
            vim.api.nvim_buf_delete(self._buf, { force = true })
        end
    end
end

---@param callbacks keystone.Tracker>
---@return keystone.TrackerRef
function Buffer:add_tracker(callbacks)
    return self._trackers:add_tracker(callbacks)
end

---@return number -- buffer number
function Buffer:get_buf()
    if vim.v.exiting ~= vim.NIL then return -1 end
    if self._destroyed then return -1 end
    return self._buf
end

function Buffer:is_destroyed()
    return self._destroyed
end

---@return number -- buffer number
---@return boolean refresh_needed
function Buffer:get_or_create_buf()
    assert(not self._destroyed)
    if vim.v.exiting ~= vim.NIL then return -1, false end

    if self._buf ~= -1 then
        local refresh_needed = false
        if not vim.api.nvim_buf_is_loaded(self._buf) then
            vim.fn.bufload(self._buf)
            self:_setup_buf()
            refresh_needed = true
        end
        return self._buf, refresh_needed
    end

    self._buf = vim.api.nvim_create_buf(false, true)
    self:_setup_buf()
    self._trackers:invoke("on_create")
    return self._buf, true
end

---@protected
function Buffer:_setup_buf()
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

    self:_apply_keymaps()
end

---@param key string
---@param keymap keystone.KeyMap
function Buffer:add_keymap(key, keymap)
    assert(not self._keymaps[key])
    self._keymaps[key] = keymap
    self:_apply_keymap(key, keymap)
end

---@param keymaps table<string, keystone.KeyMap>
function Buffer:add_keymaps(keymaps)
    for key, keymap in pairs(keymaps) do
        assert(not self._keymaps[key])
        self._keymaps[key] = keymap
        self:_apply_keymap(key, keymap)
    end
end

function Buffer:_apply_keymaps()
    if self._keymaps then
        for key, item in pairs(self._keymaps) do
            self:_apply_keymap(key, item)
        end
    end
end

---@private
---@param key string
---@param item keystone.KeyMap
function Buffer:_apply_keymap(key, item)
    if self._buf ~= -1 then
        local modes = { "n" }
        pcall(function() vim.keymap.del(modes, key, { buffer = self._buf }) end)
        vim.keymap.set(modes, key, function() item.callback() end, { buffer = self._buf, desc = item.desc })
    end
end

return Buffer
