local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")

local M = {}

---@type keystone.queryflags.FlagDef[]
local FLAGS = {
    { name = "buf",     type = "boolean", desc = "only buffer-local commands" },
    { name = "builtin", type = "boolean", desc = "only built-in commands"     },
    { name = "user",    type = "boolean", desc = "only user-defined commands" },
}

---@param cmd table
---@return string
local function format_preview(cmd)
    if cmd.is_builtin then
        return string.format("Built-in Neovim command\n\nRun  :help :%s  for documentation.", cmd.name)
    end

    local function add(lines, label, value)
        if value ~= nil and value ~= "" and value ~= 0 and value ~= false then
            table.insert(lines, string.format("- %s: %s", label, tostring(value)))
        end
    end

    local lines = {}
    add(lines, "Name",        cmd.name)
    add(lines, "Nargs",       cmd.nargs)
    add(lines, "Range",       cmd.range)
    add(lines, "Count",       cmd.count)
    add(lines, "Addr",        cmd.addr)
    add(lines, "Bang",        cmd.bang)
    add(lines, "Bar",         cmd.bar)
    add(lines, "Complete",    cmd.complete or cmd.complete_arg)
    add(lines, "Description", cmd.desc)

    table.insert(lines, "")
    table.insert(lines, "Action:")

    if cmd.callback then
        local info = debug.getinfo(cmd.callback, "S")
        table.insert(lines, "- Type: Lua callback")
        if info then
            if info.short_src then
                table.insert(lines, string.format("- Source: `%s`", info.short_src))
            end
            if info.linedefined and info.linedefined > 0 then
                table.insert(lines, string.format("- Line: %d", info.linedefined))
            end
        end
    elseif cmd.definition and cmd.definition ~= "" then
        table.insert(lines, "- Type: Vim command")
        table.insert(lines, "- Definition: " .. cmd.definition)
    else
        table.insert(lines, "_No action defined_")
    end

    return table.concat(lines, "\n")
end

function M.open()
    -- collect user-defined commands (global + buffer-local) keyed by name
    local user_cmds = {}

    for name, cmd in pairs(vim.api.nvim_get_commands({})) do
        cmd.name   = name
        user_cmds[name] = cmd
    end

    for name, cmd in pairs(vim.api.nvim_buf_get_commands(0, {})) do
        cmd.name   = name
        cmd.is_buf = true
        user_cmds[name] = cmd
    end

    -- all command names available in the current context (includes builtins)
    local all_names = vim.fn.getcompletion("", "command")

    local entries = {}

    for _, name in ipairs(all_names) do
        if user_cmds[name] then
            table.insert(entries, user_cmds[name])
        else
            table.insert(entries, { name = name, is_builtin = true, is_buf = false })
        end
    end

    if vim.tbl_isempty(entries) then
        vim.notify("No commands found", vim.log.levels.WARN)
        return
    end

    picker.open({
        prompt = "Commands",
        flags = FLAGS,
        enable_preview = true,
        finder = function(query, flags, _, callback)
            local items = {}
            for _, cmd in ipairs(entries) do
                if flags.buf     and not cmd.is_buf     then goto continue end
                if flags.builtin and not cmd.is_builtin then goto continue end
                if flags.user    and cmd.is_builtin     then goto continue end

                local match = pickertools.match_label(cmd.name, query)
                if match then
                    local chunks = match.chunks
                    if not cmd.is_builtin then
                        if cmd.desc and cmd.desc ~= "" then
                            table.insert(chunks, { "  " .. cmd.desc, "Comment" })
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
        previewer = function(data, _, callback)
            callback({ content = format_preview(data.cmd) })
            return function() end
        end,
    }, function(data)
        if not data then return end
        local name  = data.cmd.name
        local nargs = data.cmd.nargs
        local cmdline = (not data.cmd.is_builtin and nargs ~= "0") and (name .. " ") or name
        vim.api.nvim_feedkeys(":" .. cmdline, "n", false)
    end)
end

return M
