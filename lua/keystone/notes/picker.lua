---@class keystone.notes.picker
local M = {}

-- The `notes` source for the optional ezpick.nvim. It reads keystone's own note
-- store, so it lives here rather than in ezpick; `keystone.notes` registers it on
-- setup when ezpick is installed. Reached only through ezpick's registry -- so
-- ezpick is loaded by the time this module is -- and only once the source is first
-- opened.
--
-- `:Note pick` does not come through here: it prompts through `vim.ui.select`,
-- whatever that is. This spec is the richer view ezpick can offer on the same data
-- -- the location on a virtual line, file preview.

local core        = require("keystone.notes.core")
local pickertools = require("ezpick.base.pickertools")
local ui          = require("keystone.util.ui")

---@return ezpick.PickerSpec
function M.spec()
    local notes = core.sorted_notes()

    local cur_file, cur_lnum = core.get_cur_loc()
    if cur_file then cur_file = core.norm(cur_file) end

    return {
        prompt         = "Notes",
        enable_preview = true,
        finder         = function(query, _, _fetch_opts, callback)
            local items = {}
            for _, note in ipairs(notes) do
                local anchored = note.file ~= nil and note.lnum ~= nil
                local loc_text = anchored
                    and (vim.fn.fnamemodify(note.file, ":~:.") .. ":" .. note.lnum)
                    or nil
                -- Match against the note text *and* its location, so an anchored note
                -- can also be found by path. The text's highlight chunks stay on the
                -- main line; the location's go on the virt line below.
                local search_text = loc_text and (note.label .. " " .. loc_text) or note.label
                local match = pickertools.match_label(search_text, query)
                if match then
                    local label_match = pickertools.match_label(note.label, query)
                    local virt_line
                    if loc_text then
                        local loc_match = pickertools.match_label(loc_text, query)
                        local chunks = (loc_match and loc_match.chunks) or { { loc_text } }
                        -- match_label leaves unmatched chunks without a highlight; give
                        -- them the note group so the location keeps its styling, while
                        -- the matched chunks keep their match highlight.
                        for _, chunk in ipairs(chunks) do
                            if not chunk[2] then chunk[2] = "@text.note" end
                        end
                        virt_line = chunks
                    end
                    ---@type ezpick.Picker.Item
                    local item = {
                        label_chunks = (label_match and label_match.chunks) or { { note.label } },
                        virt_line    = virt_line,
                        data         = {
                            filepath = note.file,
                            lnum     = note.lnum,
                            col      = 0,
                        },
                    }
                    if anchored and cur_file and note.file == cur_file and note.lnum == cur_lnum then
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
