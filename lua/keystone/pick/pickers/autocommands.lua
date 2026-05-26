local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")

local M = {}

---@param ac vim.api.keyset.get_autocmds.ret
local function format_preview(ac)
    local function fmt(val)
        if val == nil then return nil end
        if type(val) == "table" then
            return table.concat(val, ", ")
        elseif type(val) == "boolean" then
            return val and "true" or "false"
        else
            return tostring(val)
        end
    end

    local function add(lines, label, value)
        local v = fmt(value)
        if v and v ~= "" then
            table.insert(lines, string.format("- %s: %s", label, v))
        end
    end

    local lines = {}

    add(lines, "ID", ac.id)
    add(lines, "Group", ac.group_name or ac.group)
    add(lines, "Event", ac.event)
    add(lines, "Pattern", ac.pattern or "*")
    add(lines, "Description", ac.desc)
    add(lines, "Once", ac.once)
    add(lines, "Buflocal", ac.buflocal)
    add(lines, "Buffer", ac.buffer)

    table.insert(lines, "")
    table.insert(lines, "Action:")

    if ac.command and ac.command ~= "" then
        vim.list_extend(lines, vim.split(ac.command, "\n"))
    elseif ac.callback then
        local info = debug.getinfo(ac.callback, "S")
        table.insert(lines, "- Type: Lua callback")
        if info then
            if info.short_src then
                table.insert(lines, string.format("- Source: `%s`", info.short_src))
            end
            if info.linedefined then
                table.insert(lines, string.format("- Line: %d", info.linedefined))
            end
        end
    else
        table.insert(lines, "_No action defined_")
    end

    return table.concat(lines, "\n")
end

function M.open()
    local entries = vim.api.nvim_get_autocmds({})

    if vim.tbl_isempty(entries) then
        vim.notify("No autocommands found", vim.log.levels.WARN)
        return
    end

    picker.open({
            prompt = "Autocommands",
            enable_preview = true,
            enable_list_sep = true,
            finder = function(query, _, fetch_opts, callback)
                local items = {}

                for _, ac in ipairs(entries) do
                    local label = string.format(
                        "%s │ %s │ %s",
                        ac.group_name or ac.group or "",
                        ac.event or "",
                        (ac.pattern and ac.pattern ~= "") and ac.pattern or "*"
                    )

                    local match = pickertools.match_label(label, query)
                    local virt_lines = (ac.desc and ac.desc ~= "") and {
                        { { ac.desc, "Comment" } }
                    } or {}

                    if match then
                        table.insert(items, {
                            label_chunks = match.chunks,
                            virt_lines = virt_lines,
                            score = match.score,
                            data = {
                                ac = ac
                            },
                        })
                    end
                end

                table.sort(items, function(a, b)
                    return a.score > b.score
                end)

                callback(items)
            end,
            previewer = function(data, opts, callback)
                callback({
                    content = format_preview(data.ac),
                })
                return function() end
            end
        },
        function(item)
            if not item then return end

            -- optional: show details or copy command
            vim.notify(
                string.format(
                    "Autocmd: %s [%s]",
                    item.command,
                    item.event
                ),
                vim.log.levels.INFO
            )
        end)
end

return M
