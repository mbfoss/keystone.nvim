---@brief Two subtle highlights shared across keystone modules.
---
---`KeystoneSubtle` and `KeystoneSubtleFaint` are `NonText` faded into the
---background, at 40% and 60%. `blend=` applies only to floats and the popup
---menu, so the fade is baked into a colour instead, and only the foreground is
---carried over: a background would paint a block behind the one-cell guides.
---Both are rebuilt from the current colorscheme on every `ColorScheme`.

local M = {}

local color = require("keystone.util.color")

local _SUBTLE = "KeystoneSubtle"
local _FAINT = "KeystoneSubtleFaint"
local _SUBTLE_FADE_PCT = 40
local _FAINT_FADE_PCT = 60

local _setup = false

---Define the two groups from the current colorscheme, once, on first use; the
---`ColorScheme` autocmd `color.create_themed_hl` installs rebuilds them after.
local function _setup_once()
    if _setup then return end
    _setup = true
    color.create_themed_hl({
        name = _SUBTLE,
        spec = function() return color.faded_hl_info("NonText", _SUBTLE_FADE_PCT) end,
    })
    color.create_themed_hl({
        name = _FAINT,
        spec = function() return color.faded_hl_info("NonText", _FAINT_FADE_PCT) end,
    })
end

---The subtle group: `NonText` faded 40% into the background. Defines the
---groups on first call.
---@return string
function M.subtle()
    _setup_once()
    return _SUBTLE
end

---The fainter group: `NonText` faded 60% into the background. Defines the
---groups on first call.
---@return string
function M.faint()
    _setup_once()
    return _FAINT
end

return M
