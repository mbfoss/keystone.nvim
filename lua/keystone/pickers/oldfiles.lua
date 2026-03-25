local M = {}

local uitools = require("keystone.tools.uitools")
local picker = require('keystone.tools.picker')
local pickertools = require("keystone.tools.pickertools")

function M.open()
    local cwd = vim.fn.getcwd()
    local recent_files = {}

    -- 1. Gather files regardless of CWD
    for _, path in ipairs(vim.v.oldfiles) do
        local full_path = vim.fn.fnamemodify(path, ":p")

        if vim.fn.filereadable(full_path) == 1 then
            local match_path
            if full_path:find(cwd, 1, true) == 1 then
                match_path = vim.fn.fnamemodify(full_path, ":.")
            else
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
                -- Calculate how far the filename is from the start of the match_path
                local offset = #file.match_path - #file.filename

                -- Use generic tool for matching filename vs match_path
                local res = pickertools.make_picker_item(file.filename, query, file.match_path, {
                    list_width = fetch_opts.list_width,
                    is_path = true,
                    offset = offset
                })

                if res then
                    table.insert(items, {
                        label_chunks = res.chunks,
                        data = file.full_path,
                        score = res.score
                    })
                end
            end

            if query ~= "" then
                table.sort(items, function(a, b) return a.score > b.score end)
            end
            return items
        end,
        async_preview = pickertools.default_file_preview,
    }, function(selected_path)
        if selected_path then
            uitools.smart_open_file(selected_path)
        end
    end)
end

return M
