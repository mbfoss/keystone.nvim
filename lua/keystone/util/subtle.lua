---@brief One subtle highlight shared across keystone modules.
---
---`KeystoneSubtle` is `NonText` faded into the background. `blend=` applies only
---to floats and the popup menu, so the fade is baked into a colour instead, and
---only the foreground is carried over: a background would paint a block behind
---the one-cell guides. It is rebuilt from the current colorscheme on every
---`ColorScheme`.

local M = {}

local color = require("keystone.util.color")

local _SUBTLE = "KeystoneSubtle"
local _SUBTLE_FADE_PCT = 60

local _setup = false

---Define the group from the current colorscheme, once, on first use; the
---`ColorScheme` autocmd `color.create_themed_hl` installs rebuilds it after.
local function _setup_once()
    if _setup then return end
    _setup = true
    color.create_themed_hl({
        name = _SUBTLE,
        spec = function() return color.faded_hl_info("NonText", _SUBTLE_FADE_PCT) end,
    })
end

---The subtle group: `NonText` faded into the background. Defines the group on
---first call.
---@return string
function M.subtle()
    _setup_once()
    return _SUBTLE
end

return M
