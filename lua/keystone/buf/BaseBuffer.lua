local class = require('keystone.utils.class')
local Trackers = require('keystone.utils.Trackers')
local throttle = require('keystone.utils.throttle')

---@class keystone.KeyMap
---@field callback fun()
---@field desc string
---@
---@alias keystone.Keymaps table<string,keystone.KeyMap>

---@class keystone.Tracker
---@field on_create fun()?
---@field on_change fun()?
---@field on_delete fun()?

---@class keystone.BaseBufferOpts
---@field name string
---@field filetype string
---@field listed boolean
---@field wipe_when_hidden boolean

---@class keystone.BaseBuffer
---@field new fun(self: keystone.BaseBuffer, opts:keystone.BaseBufferOpts): keystone.BaseBuffer
local BaseBuffer = class()

---@param opts keystone.BaseBufferOpts
function BaseBuffer:init(opts)
    vim.validate("opts", opts, "table")
    vim.validate("opts.name", opts.name, "string")
    vim.validate("opts.filetype", opts.filetype, "string")
    vim.validate("opts.listed", opts.listed, { "nil", "boolean" })
    vim.validate("opts.wipe_when_hidden", opts.wipe_when_hidden, "boolean")
    self._filetype = opts.filetype
    self._name = opts.name
    self._listed = opts.listed
    self._wipe_when_hidden = opts.wipe_when_hidden
    self._keymaps = {}
    self._buf = -1

    self._trackers = Trackers:new()

    self._throttled_change_notif = throttle.throttle_wrap(100, function()
        self._trackers:invoke("on_change")
    end)
end

function BaseBuffer:destroy()
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

function BaseBuffer:request_change_notif()
    if not self._no_change_events then
        self._throttled_change_notif()
    end
end

function BaseBuffer:set_user_data(data)
    self._user_data = data
end

function BaseBuffer:get_user_data()
    return self._user_data
end

---@param callbacks keystone.Tracker>
---@return keystone.TrackerRef
function BaseBuffer:add_tracker(callbacks)
    return self._trackers:add_tracker(callbacks)
end

function BaseBuffer:disable_change_events()
    self._no_change_events = true
end

---@private
function BaseBuffer:_on_buf_enter()
    self:_apply_keymaps()
end

---@return string
function BaseBuffer:get_name()
    return self._name
end

---@return number -- buffer number
function BaseBuffer:get_buf()
    if vim.v.exiting ~= vim.NIL then return -1 end
    if self._destroyed then return -1 end
    return self._buf
end

function BaseBuffer:is_destroyed()
    return self._destroyed
end

---@return number -- buffer number
---@return boolean refresh_needed
function BaseBuffer:get_or_create_buf()
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
function BaseBuffer:_setup_buf()
    assert(self._buf > 0)
    assert(type(self._filetype) == "string" and self._filetype ~= "")

    local buf = self._buf

    local bufname = "loop://" .. self._name
    if vim.fn.bufexists(bufname) == 1 then
        bufname = "loop://" .. tostring(buf) .. '/' .. self._name
    end
    if vim.fn.bufexists(bufname) == 1 then
        ---@diagnostic disable-next-line: undefined-field
        local timestamp = ("%d"):format(vim.uv.hrtime())
        bufname = "loop://" .. tostring(buf) .. timestamp .. '/' .. self._name
    end

    vim.api.nvim_buf_set_name(buf, bufname)

    assert(type(self._wipe_when_hidden) == "boolean")
    assert(type(self._listed) == "boolean")
    do
        local b = vim.bo[buf]
        b.buftype = "nofile"
        b.bufhidden = self._wipe_when_hidden and "wipe" or (self._listed and "" or "hide")
        b.filetype = self._filetype
        b.modifiable = false
        b.swapfile = false
        b.undolevels = -1          -- buffer can't become "modified"
        b.buflisted = self._listed -- hide from :ls
        b.modeline = false
        b.spelloptions = "noplainbuffer"
    end

    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        buffer = buf,
        once = true,
        callback = function(ev)
            assert(ev.buf == buf)
            self._buf = -1
            self._trackers:invoke("on_delete") -- must be immediate to syncronise with on_create
        end,
    })

    vim.api.nvim_create_autocmd("BufEnter", {
        buffer = buf,
        callback = function(ev)
            assert(ev.buf == buf)
            self:_on_buf_enter()
        end
    })
end

---@param key string
---@param keymap keystone.KeyMap
function BaseBuffer:add_keymap(key, keymap)
    assert(not self._keymaps[key])
    self._keymaps[key] = keymap
    self:_apply_keymap(key, keymap)
end

---@param keymaps table<string, keystone.KeyMap>
function BaseBuffer:add_keymaps(keymaps)
    for key, keymap in pairs(keymaps) do
        assert(not self._keymaps[key])
        self._keymaps[key] = keymap
        self:_apply_keymap(key, keymap)
    end
end

function BaseBuffer:_apply_keymaps()
    if self._keymaps then
        for key, item in pairs(self._keymaps) do
            self:_apply_keymap(key, item)
        end
    end
end

---@private
---@param key string
---@param item keystone.KeyMap
function BaseBuffer:_apply_keymap(key, item)
    if self._buf ~= -1 then
        local modes = { "n" }
        pcall(function() vim.keymap.del(modes, key, { buffer = self._buf }) end)
        vim.keymap.set(modes, key, function() item.callback() end, { buffer = self._buf, desc = item.desc })
    end
end

return BaseBuffer
