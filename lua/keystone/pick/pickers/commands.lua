local M = {}

local pickertools = require("keystone.pick.base.pickertools")

--- A command entry: the raw info from `nvim_get_commands` (under `info`) tagged
--- with the source flags this picker tracks.  `nvim_get_commands` never returns
--- a `desc` field — for Lua-callback commands the description is reported in
--- `info.definition`, while for `:command`-defined commands `info.definition` is
--- the command body.
---@class keystone.pick.CommandEntry
---@field is_builtin boolean?
---@field is_buf boolean?
---@field info vim.api.keyset.command_info

---@type keystone.queryflags.FlagDef[]
local FLAGS = {
    { name = "buflocal", type = "boolean", desc = "only buffer-local commands" },
    { name = "builtin",  type = "boolean", desc = "only built-in commands" },
    { name = "user",     type = "boolean", desc = "only user-defined commands" },
}

--- Collect every command available in the current buffer: user/buffer-local
--- commands (with full info) merged over the names reported by completion, so
--- built-ins that have no info entry still show up.
---@return keystone.pick.CommandEntry[]
local function collect_commands()
    ---@type table<string, keystone.pick.CommandEntry>
    local by_name = {}

    for name, cmd in pairs(vim.api.nvim_get_commands({})) do
        by_name[name] = { info = cmd }
    end
    for name, cmd in pairs(vim.api.nvim_buf_get_commands(0, {})) do
        by_name[name] = { info = cmd, is_buf = true }
    end

    ---@type keystone.pick.CommandEntry[]
    local entries = {}
    for _, name in ipairs(vim.fn.getcompletion("", "command")) do
        -- built-ins have no info entry; synthesize one carrying just the name
        ---@diagnostic disable-next-line: missing-fields
        entries[#entries + 1] = by_name[name] or { is_builtin = true, info = { name = name } }
    end
    return entries
end

---@return keystone.PickerSpec?
function M.spec()
    local entries = collect_commands()

    if vim.tbl_isempty(entries) then
        vim.notify("No commands found", vim.log.levels.WARN)
        return nil
    end

    return {
        prompt     = "Commands",
        flags      = FLAGS,
        finder     = function(query, flags, _, callback)
            local items = {}
            for _, cmd in ipairs(entries) do
                if flags.buflocal and not cmd.is_buf then goto continue end
                if flags.builtin and not cmd.is_builtin then goto continue end
                if flags.user and cmd.is_builtin then goto continue end

                local info  = cmd.info
                local match = pickertools.match_label(info.name, query)
                if match then
                    local chunks = match.chunks
                    if not cmd.is_builtin then
                        -- `definition` is the human description for Lua callbacks
                        -- and the command body for `:command`-defined commands.
                        if info.definition and info.definition ~= "" then
                            table.insert(chunks, { "  " .. info.definition, "Comment" })
                        end
                        if cmd.is_buf then
                            table.insert(chunks, { " [buf]", "Special" })
                        end
                    end
                    table.insert(items, {
                        label_chunks = chunks,
                        score        = match.score,
                        data         = { cmd = cmd },
                    })
                end
                ::continue::
            end
            table.sort(items, function(a, b) return a.score > b.score end)
            callback(items)
        end,
        on_confirm = function(data)
            if not data then return end
            ---@type keystone.pick.CommandEntry
            local cmd     = data.cmd
            local info    = cmd.info
            local cmdline = (not cmd.is_builtin and info.nargs ~= "0") and (info.name .. " ") or info.name
            vim.api.nvim_feedkeys(":" .. cmdline, "n", false)
        end,
    }
end

return M
