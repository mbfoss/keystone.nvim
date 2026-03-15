local M = {}

local uitools = require("keystone.tools.uitools")
local strtools = require("keystone.tools.strtools")
local filetools = require("keystone.tools.file")
local picker = require('keystone.tools.picker')

local function _build_label_chunks(display, positions)
    if not positions or #positions == 0 then return { { display } } end
    local chunks, pos_map = {}, {}
    for _, p in ipairs(positions) do pos_map[p] = true end
    local current_chunk = ""
    local last_was_match = pos_map[1] or false
    for i = 1, #display do
        local is_match = pos_map[i] or false
        if is_match ~= last_was_match then
            table.insert(chunks, last_was_match and { current_chunk, "Label" } or { current_chunk })
            current_chunk = display:sub(i, i)
            last_was_match = is_match
        else
            current_chunk = current_chunk .. display:sub(i, i)
        end
    end
    if current_chunk ~= "" then
        table.insert(chunks, last_was_match and { current_chunk, "Label" } or { current_chunk })
    end
    return chunks
end

function M.open()
    local cwd = vim.fn.getcwd()
    local recent_files = {}

    -- 1. Gather files regardless of CWD
    for _, path in ipairs(vim.v.oldfiles) do
        local full_path = vim.fn.fnamemodify(path, ":p")
        
        -- Basic sanity checks: readable, not a directory, not a temporary buffer
        if vim.fn.filereadable(full_path) == 1 then
            -- Determine the "best" path for display/matching
            local match_path
            if full_path:find(cwd, 1, true) == 1 then
                -- Inside CWD: use relative path
                match_path = vim.fn.fnamemodify(full_path, ":.")
            else
                -- Outside CWD: use ~ for home or absolute path
                match_path = vim.fn.fnamemodify(full_path, ":~")
            end
            
            table.insert(recent_files, {
                full_path = full_path,
                match_path = match_path,
                filename = vim.fn.fnamemodify(full_path, ":t")
            })
        end
        if #recent_files >= 500 then break end
    end

    picker.select({
        prompt = "Global Recent Files",
        file_preview = true,
        fetch = function(query, fetch_opts)
            local items = {}
            for _, file in ipairs(recent_files) do
                -- Fuzzy match only against the filename
                local is_match, score, positions = strtools.fuzzy_match(file.filename, query)
                
                if is_match or query == "" then
                    -- Crop based on the match_path (the path we decided to show)
                    local display = strtools.smart_crop_path(file.match_path, fetch_opts.list_width)
                    
                    -- Offset Math:
                    -- file.match_path is what we display.
                    -- file.filename is what we matched.
                    local filename_start_in_display = #file.match_path - #file.filename
                    local crop_offset = #display - #file.match_path
                    
                    local adjusted_positions = {}
                    if positions then
                        for _, p in ipairs(positions) do
                            local adj = p + filename_start_in_display + crop_offset
                            if adj >= 1 then table.insert(adjusted_positions, adj) end
                        end
                    end

                    table.insert(items, {
                        label_chunks = _build_label_chunks(display, adjusted_positions),
                        data = file.full_path,
                        score = score or 0
                    })
                end
            end

            if query ~= "" then
                table.sort(items, function(a, b) return a.score > b.score end)
            end
            return items
        end,
        async_preview = function(item_data, _, callback)
            return filetools.async_load_text_file(item_data, nil, function(_, content)
                callback(content, { filepath = item_data })
            end)
        end,
    }, function(selected_path)
        if selected_path then
            uitools.smart_open_file(selected_path)
        end
    end)
end

return M