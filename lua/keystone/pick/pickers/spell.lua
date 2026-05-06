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

    picker.open({
        prompt = "Spell Checker: " .. cursor_word,
        fetch = function(query, fetch_opts)
            local items = {}
            for i, word in ipairs(suggestions) do
                local item = {
                    label = word,
                    data = {
                        word = word
                    }
                }
                local match = pickertools.match_label(item.label, query)

                if match then
                    item.label_chunks = match.chunks
                    item.score = match.score - (i * 0.01)
                    table.insert(items, item)
                end
            end
            return items
        end,
    }, function(data)
        if data then
            vim.cmd("normal! ciw" .. data.word)
        end
    end)
end

return M
