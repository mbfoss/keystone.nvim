local picker = require("keystone.pick.base.picker")
local pickertools = require("keystone.pick.base.pickertools")

local M = {}
function M.open(opts)
    opts = opts or {}

    local cursor_word = vim.fn.expand("<cword>")
    if cursor_word == "" then
        vim.notify("No word under cursor", vim.log.levels.WARN)
        return
    end

    local suggestions = vim.fn.spellsuggest(cursor_word, opts.limit or 25)

    if #suggestions == 0 then
        vim.notify("No spell suggestions found for: " .. cursor_word, vim.log.levels.INFO)
        return
    end

    picker.select({
        prompt = "Spell Checker: " .. cursor_word,
        file_preview = false,
        fetch = function(query, fetch_opts)
            local items = {}
            for i, word in ipairs(suggestions) do
                local item = {
                    label = word,
                    data = word
                }
                local match = pickertools.make_picker_item(item.label, query, {
                    list_width = fetch_opts.list_width,
                    is_path = false
                })

                if match then
                    item.label_chunks = match.chunks
                    item.score = match.score - (i * 0.01)
                    table.insert(items, item)
                end
            end
            return items
        end,
    }, function(word)
        if word then
            vim.cmd("normal! ciw" .. word)
        end
    end)
end

return M
