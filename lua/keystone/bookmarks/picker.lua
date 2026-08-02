---@class keystone.bookmarks.picker
local M = {}

-- The `bookmarks` source for the optional ezpick.nvim. It reads keystone's own
-- extmark-backed bookmark store, so it lives here rather than in ezpick;
-- `keystone.bookmarks` registers it on setup when ezpick is installed. Reached
-- only through ezpick's registry -- so ezpick is loaded by the time this module
-- is -- and only once the source is first opened.
--
-- `:Bookmark pick` does not come through here: it prompts through
-- `vim.ui.select`, whatever that is. This spec is the richer view ezpick can
-- offer on the same data -- labels on a virtual line, file preview.

local core        = require("keystone.bookmarks.core")
local pickertools = require("ezpick.base.pickertools")
local ui          = require("keystone.util.ui")

---@return ezpick.PickerSpec
function M.spec()
    local entries = core.sorted_entries()

    local cur_file, cur_lnum = core.get_cur_loc()
    if cur_file then cur_file = core.norm(cur_file) end

    return {
        prompt         = "Bookmarks",
        enable_preview = true,
        finder         = function(query, _, _fetch_opts, callback)
            local items = {}
            for _, entry in ipairs(entries) do
                local relpath = vim.fn.fnamemodify(entry.file, ":~:.")
                local loc_text = relpath .. ":" .. entry.lnum
                local label = entry.label
                -- Match against the location *and* the label, so a bookmark can be
                -- found by words in its note. The location's highlight chunks stay on
                -- the main line; the label's go on the virt line below (note base).
                local search_text = label and (loc_text .. " " .. label) or loc_text
                local match = pickertools.match_label(search_text, query)
                if match then
                    local loc_match = pickertools.match_label(loc_text, query)
                    local virt_line
                    if label then
                        local label_match = pickertools.match_label(label, query)
                        local chunks = (label_match and label_match.chunks) or { { label } }
                        -- match_label leaves unmatched chunks without a highlight; give
                        -- them the note group so the label keeps its styling, while the
                        -- matched chunks keep their match highlight.
                        for _, chunk in ipairs(chunks) do
                            if not chunk[2] then chunk[2] = "@text.note" end
                        end
                        virt_line = chunks
                    end
                    ---@type ezpick.Picker.Item
                    local item = {
                        label_chunks = (loc_match and loc_match.chunks) or { { loc_text } },
                        virt_line    = virt_line,
                        data         = {
                            filepath = entry.file,
                            lnum     = entry.lnum,
                            col      = 0,
                        },
                    }
                    if cur_file and entry.file == cur_file and entry.lnum == cur_lnum then
                        item.initial = true
                    end
                    table.insert(items, item)
                end
            end
            callback(items)
        end,
        on_confirm     = function(data)
            if data and data.filepath then
                ui.smart_open_file(data.filepath, data.lnum, data.col)
            end
        end,
    }
end

return M
