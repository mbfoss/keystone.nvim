local M = {}

local pickertools = require("keystone.pick.base.pickertools")

--- A command entry: the raw info from `nvim_get_commands` (under `info`) tagged
--- with the source flags this picker tracks.  `nvim_get_commands` never returns
--- a `desc` field — for Lua-callback commands the description is reported in
--- `info.definition`, while for `:command`-defined commands `info.definition` is
--- the command body.  Built-ins have no info of their own, so we synthesize one
--- and borrow a one-liner from Neovim's help index as the `definition`.
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

---@type table<string, string>?
local _builtin_desc

--- Short one-line descriptions for built-in Ex commands, parsed on demand from
--- Neovim's bundled `doc/index.txt` (the `ex-cmd-index` table) so they stay in
--- sync with the running version.  Built-ins expose no description of their own.
--- Each entry there reads `|:tag|<tab>:ab[brev]<tab>description`; the full
--- command name is the abbreviation with its `[...]` optional part flattened
--- (`:a[ppend]` -> `append`).  Memoised after the first call.
---@return table<string, string> name -> description
local function builtin_descriptions()
    if _builtin_desc then return _builtin_desc end
    _builtin_desc = {}

    local file = vim.api.nvim_get_runtime_file("doc/index.txt", false)[1]
    if not file then return _builtin_desc end

    local ok, lines = pcall(vim.fn.readfile, file)
    if not ok then return _builtin_desc end

    local in_section = false
    for _, line in ipairs(lines) do
        if not in_section then
            in_section = line:find("*ex-cmd-index*", 1, true) ~= nil
        else
            local abbrev, desc = line:match("^|:[^|]*|%s+:(%S+)%s+(.+)$")
            if abbrev then
                _builtin_desc[(abbrev:gsub("[%[%]]", ""))] = vim.trim(desc)
            end
        end
    end
    return _builtin_desc
end

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

    local descs = builtin_descriptions()

    ---@type keystone.pick.CommandEntry[]
    local entries = {}
    for _, name in ipairs(vim.fn.getcompletion("", "command")) do
        -- built-ins have no info entry; synthesize one and borrow its blurb
        -- from the help index parsed above.
        ---@diagnostic disable-next-line: missing-fields
        entries[#entries + 1] = by_name[name]
            or { is_builtin = true, info = { name = name, definition = descs[name] } }
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
                    -- `definition` is the description for Lua callbacks, the body
                    -- for `:command`-defined commands, and the help one-liner for
                    -- built-ins.
                    if info.definition and info.definition ~= "" then
                        table.insert(chunks, { "  " .. info.definition, "Comment" })
                    end
                    if cmd.is_buf then
                        table.insert(chunks, { " [buf]", "Special" })
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
