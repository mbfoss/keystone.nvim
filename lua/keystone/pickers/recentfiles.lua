local M = {}

local uitools = require("keystone.utils.uitools")
local picker = require('keystone.utils.picker')
local pickertools = require("keystone.utils.pickertools")

function M.open()
    local cwd = vim.fn.getcwd()

    local recent_files = {}
    local seen = {}
    local curbuf = vim.api.nvim_get_current_buf()
    local bufs = vim.fn.getbufinfo({ buflisted = 1 })
    table.sort(bufs, function(a, b) return a.lastused > b.lastused end)
    for _, info in ipairs(bufs) do
        if info.bufnr ~= curbuf then
            local full_path = vim.fn.fnamemodify(info.name, ":p")
            if full_path ~= "" and vim.fn.filereadable(full_path) == 1 then
                seen[full_path] = true
                local match_path = (full_path:find(cwd, 1, true) == 1)
                    and vim.fn.fnamemodify(full_path, ":.")
                    or vim.fn.fnamemodify(full_path, ":~")
                table.insert(recent_files, {
                    full_path = full_path,
                    match_path = match_path,
                    filename = vim.fn.fnamemodify(full_path, ":t")
                })
            end
        end
    end
    for _, path in ipairs(vim.v.oldfiles) do
        if #recent_files >= 500 then break end
        local full_path = vim.fn.fnamemodify(path, ":p")
        if not seen[full_path] and vim.fn.filereadable(full_path) == 1 then
            seen[full_path] = true
            local match_path = (full_path:find(cwd, 1, true) == 1)
                and vim.fn.fnamemodify(full_path, ":.")
                or vim.fn.fnamemodify(full_path, ":~")
            table.insert(recent_files, {
                full_path = full_path,
                match_path = match_path,
                filename = vim.fn.fnamemodify(full_path, ":t")
            })
        end
    end

    picker.select({
        prompt = "Recent Files",
        file_preview = true,
        fetch = function(query, fetch_opts)
            local items = {}
            for _, file in ipairs(recent_files) do
                local res = pickertools.make_picker_item(file.match_path, query, {
                    list_width = fetch_opts.list_width,
                    is_path = true,
                })
                if res then
                    table.insert(items, {
                        label_chunks = res.chunks,
                        data = file.full_path,
                    })
                end
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
