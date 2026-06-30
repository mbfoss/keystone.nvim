local strutil        = require("keystone.util.strutil")
local uitool         = require("keystone.util.uitool")
local fsutil         = require("keystone.util.fsutil")
local TreeBuffer     = require("keystone.util.TreeBuffer")
local LRU            = require("keystone.util.LRU")
local floatwin       = require("keystone.util.floatwin")
local inputwin       = require("keystone.util.inputwin")
local common         = require("keystone.util.timer")
local icons          = require("keystone.icons")

---@class keystone.FileTree.ItemData
---@field path string
---@field name string
---@field loname string
---@field is_dir boolean
---@field is_link boolean?
---@field icon string
---@field icon_hl string
---@field is_current boolean?
---@field error_flag boolean?
---@field error_icon string?
---@field children_loading boolean?
---@field childrenload_req_id number

---@alias keystone.FileTree.ItemDef keystone.util.TreeBuffer.ItemData

---@class keystone.FileTree.PrepareDirEntry
---@field name string
---@field type string

---@class keystone.FileTree.ProcessDirEntry
---@field name string
---@field is_dir boolean
---@field is_link boolean

---@class keystone.FileTree.UpsetSingleItemArgs
---@field parent_path string
---@field full_path string
---@field name string
---@field loname string
---@field is_dir boolean
---@field is_link boolean?

local _error_node_id = {} -- unique id for the error node

local function _show_help()
    local help_text = { [[
NAVIGATION
==========
`<CR>`    Open file / Toggle directory

FOLDING
=======
`za`      Toggle expand/collapse
`zc`      Collapse
`zo`      Expand
`zC`      Collapse (recursive)
`zO`      Expand (recursive)

MANAGEMENT
==========
`a`       Create file at location
`i`       Create file inside directory
`A`       Create directory at location
`I`       Create directory inside directory
`r`       Rename file or directory

SELECTION
=========
`<Tab>`   Toggle selection of item under cursor
`<Tab>`   (visual) Toggle selection of items in the visual selection
`X`       Move selected items into the directory under cursor
`C`       Copy selected items into the directory under cursor
`D`       Delete selected items (system trash if available)

OTHER
=====
`gh`      Toggle hidden files
`K`       Hover info (type, size, modified)
`R`       Refresh tree
`g?`      Show this help]]
    }

    floatwin.open(table.concat(help_text, "\n"), {
        title = "File Tree",
        is_markdown = true,
    })
end

---@param id string
---@param data keystone.FileTree.ItemData
---@param selected boolean?
local function _file_formatter(id, data, selected)
    if not data then return {}, {} end
    local virt_chunks = {}
    if data.is_link then
        table.insert(virt_chunks, { "↗", "Special" })
    end
    if data.error_flag then
        table.insert(virt_chunks, { data.error_icon or "⚠", "ErrorMsg" })
    end
    if selected then
        table.insert(virt_chunks, { "●", "Special" })
    end
    local name_hl = selected and "Visual" or (data.is_current and "Type" or nil)
    local chunks = {
        { data.icon, data.icon_hl },
        { " " },
        { data.name, name_hl }
    }
    return chunks, virt_chunks
end


local function _is_regular_buffer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then return false end
    if vim.bo[bufnr].buftype ~= '' then return false end
    return true
end

---@class keystone.FileTree.Opts
---@field dir string?
---@field follow_cwd boolean?
---@field show_hidden boolean?
---@field track_current_file {enabled:boolean?,auto_collapse_others:boolean?}?
---@field monitor_file_system boolean?
---@field max_monitored_folders number?

---@class keystone.FileTree
---@field new fun(self:keystone.FileTree, opts:keystone.FileTree.Opts?):keystone.FileTree
---@field private _selected table<string, true>
local FileTree = {}
FileTree.__index = FileTree

function FileTree:new(...)
    local obj = setmetatable({}, self)
    if obj.init then obj:init(...) end
    return obj
end

---@param opts keystone.FileTree.Opts
function FileTree:init(opts)
    self._opts = opts and vim.deepcopy(opts) or {}
    self._monitor_lru = LRU:new(self._opts.max_monitored_folders or 100, {
        on_removed = function(path, cancel_fn)
            cancel_fn()
        end,
    })

    self._show_hidden = self._opts.show_hidden == true
    self._viewport_monitor_fn = self:_get_viewport_monitor_fn()
    self._toggle_counter = 0
    self._reload_counter = 0

    self._pending_expand = {}
    self._pending_reveal = nil

    self._selected = {} ---@type table<string, true> Set of selected item paths

    self:_setup_tree()
end

function FileTree:_setup_tree()
    assert(not self._treebuf)

    self._treebuf = TreeBuffer.new({
        formatter = function(id, data)
            return _file_formatter(id, data, self._selected[data.path] == true)
        end,
    })

    self._treebuf:subscribe({
        on_selection = function(id, data)
            if not data.is_dir and fsutil.file_exists(data.path) then
                uitool.smart_open_file(data.path)
            end
        end,
        on_toggle = function(id, data, expanded)
            self._toggle_counter = self._toggle_counter + 1
            if data.is_dir and expanded then
                local old = data.childrenload_req_id
                self._viewport_monitor_fn()
                if old == data.childrenload_req_id then
                    self:_read_dir(data.path, self._reload_counter, true)
                end
            end
        end,
    })
end

function FileTree:_on_buffer_created()
    assert(not self._bufenter_autocmd_id)
    assert(not self._dirchanged_autocmd_id)

    local track_config = self._opts.track_current_file or {}
    local track_collapse_others = track_config.auto_collapse_others ~= false
    local on_buffer_enter = function()
        if self._treebuf:get_bufnr() == -1 then
            return
        end
        local buf = vim.api.nvim_get_current_buf()
        if _is_regular_buffer(buf) then
            local path = vim.api.nvim_buf_get_name(buf)
            if path ~= "" then
                vim.schedule(function()
                    self:_reveal(path, track_collapse_others, true)
                end)
            end
        end
    end
    local on_dir_changed = function()
        vim.schedule(function()
            self:_set_root(vim.fn.getcwd())
        end)
    end

    if track_config.enabled ~= false then
        self._bufenter_autocmd_id = vim.api.nvim_create_autocmd("BufEnter", {
            callback = on_buffer_enter,
        })
    end

    if self._opts.follow_cwd ~= false then
        self._dirchanged_autocmd_id = vim.api.nvim_create_autocmd("DirChanged", {
            callback = on_dir_changed,
        })
    end
    self:_set_root(self._opts.dir or vim.fn.getcwd())
end

function FileTree:_on_buffer_deleted()
    if self._bufenter_autocmd_id then
        vim.api.nvim_del_autocmd(self._bufenter_autocmd_id)
        self._bufenter_autocmd_id = nil
    end
    if self._dirchanged_autocmd_id then
        vim.api.nvim_del_autocmd(self._dirchanged_autocmd_id)
        self._dirchanged_autocmd_id = nil
    end
    self:_clear_all_monitors()
end

---@private
---@return fun()
function FileTree:_get_viewport_monitor_fn()
    local lastwinid, topline, botline, toggle_counter
    return function()
        local buf = self._treebuf:get_bufnr()
        if buf <= 0 then return end

        local winid = vim.fn.bufwinid(buf)
        if winid <= 0 then return end

        local info = vim.fn.getwininfo(winid)[1]
        if not info then return end
        if winid ~= lastwinid or info.topline ~= topline or info.botline ~= botline or toggle_counter ~= self._toggle_counter then
            lastwinid, topline, botline, toggle_counter = winid, info.topline, info.botline, self._toggle_counter

            local visible_items = self._treebuf:get_visible_items(winid)
            local active_folders = {}
            for _, item in ipairs(visible_items) do
                local parent = self._treebuf:get_parent_item(item.id)
                if parent then
                    active_folders[parent.data.path] = true
                end
                if item.data.is_dir and item.expanded then
                    active_folders[item.data.path] = true
                end
            end
            for _, path in ipairs(self._monitor_lru:keys()) do
                if not active_folders[path] then
                    self._monitor_lru:delete(path)
                end
            end
            for path, _ in pairs(active_folders) do
                if self:_start_dir_monitor(path) then
                    self:_read_dir(path, self._reload_counter, false)
                end
            end
        end
    end
end

---@return integer bufr
function FileTree:create_buffer()
    local bufnr, created = self._treebuf:create_buffer(function()
        self:_on_buffer_deleted()
    end)

    if not created then return bufnr end

    local function with_item(fn)
        local item = self._treebuf:get_cursor_item()
        if item then fn(item) end
    end

    local keymaps = {
        ["a"] = {
            function()
                with_item(function(i) self:_create_node(i, false, true) end)
            end,
            "Create File",
        },
        ["A"] = {
            function()
                with_item(function(i) self:_create_node(i, true, true) end)
            end,
            "Create Directory",
        },
        ["i"] = {
            function()
                with_item(function(i) self:_create_node(i, false, false) end)
            end,
            "Create File (inside)",
        },
        ["I"] = {
            function()
                with_item(function(i) self:_create_node(i, true, false) end)
            end,
            "Create Directory (inside)",
        },
        ["r"] = {
            function()
                with_item(function(i) self:_rename_node(i) end)
            end,
            "Rename file or directory",
        },
        ["D"] = {
            function()
                local items = self:_get_selected_items()
                if #items == 0 then
                    vim.notify("No items selected", vim.log.levels.WARN)
                    return
                end
                self:_delete_items(items)
            end,
            "Delete selected items (system trash if available)",
        },
        ["<Tab>"] = {
            function()
                with_item(function(i) self:_toggle_select(i) end)
            end,
            "Toggle selection",
        },
        ["X"] = {
            function()
                with_item(function(i) self:_transfer_selected(i, false) end)
            end,
            "Move selected items here",
        },
        ["C"] = {
            function()
                with_item(function(i) self:_transfer_selected(i, true) end)
            end,
            "Copy selected items here",
        },
        ["gh"] = {
            function()
                self:_toggle_hidden()
            end,
            "Toggle hidden files",
        },
        ["K"] = {
            function()
                with_item(function(i) self:_show_hover(i) end)
            end,
            "Show hover info",
        },
        ["R"] = {
            function()
                self:_on_refresh_by_user()
            end,
            "Refresh tree",
        },
        ["g?"] = {
            function()
                _show_help()
            end,
            "Show Help",
        },
    }

    assert(bufnr > 0)
    for key, map in pairs(keymaps) do
        vim.api.nvim_buf_set_keymap(bufnr, "n", key, "", { callback = map[1], desc = map[2] })
    end

    vim.api.nvim_buf_set_keymap(bufnr, "x", "<Tab>", "", {
        callback = function() self:_visual_select() end,
        desc = "Toggle selection of items in visual selection",
    })

    self:_on_buffer_created()

    return bufnr
end

function FileTree:get_bufnr()
    return self._treebuf:get_bufnr()
end

---@param rel string
---@param is_dir boolean
---@return boolean
function FileTree:_should_include(rel, is_dir)
    if is_dir then
        return strutil.check_path_pattern(rel, true, nil, self._exclude_patterns)
    end
    return strutil.check_path_pattern(rel, false, self._include_patterns, self._exclude_patterns)
end

---@private
---@param path string
---@return boolean
function FileTree:_start_dir_monitor(path)
    if self._opts.monitor_file_system == false then
        return false
    end
    if self._monitor_lru:has(path) then
        return false
    end
    local cancel_fn, error_msg = fsutil.monitor_dir(path, function(name, status)
        local reload_counter = self._reload_counter
        ---@type keystone.FileTree.ProcessDirEntry[]
        if reload_counter ~= self._reload_counter then return end
        if self._treebuf:get_bufnr() ~= -1 then
            self:_read_dir(path, reload_counter, false)
        end
    end)
    if not cancel_fn then
        return false
    end
    self._monitor_lru:put(path, cancel_fn)
    return true
end

function FileTree:_clear_all_monitors()
    self._monitor_lru:clear()
end

---@param root string?
---@param include_globs string[]?
---@param exclude_globs string[]?
---@param follow_symlinks boolean?
function FileTree:_set_root(root, include_globs, exclude_globs, follow_symlinks)
    if not self._show_hidden then
        exclude_globs = exclude_globs and vim.copy(exclude_globs) or {}
        table.insert(exclude_globs, ".*")
        table.insert(exclude_globs, "**/.*")
    end

    -- it's important to normalize the path because we use / as sperator
    local newroot = root and vim.fs.normalize(root) or nil
    if self._root and self._root ~= newroot then
        self:_clear()
    end
    self._root = newroot
    self._include_patterns = include_globs and strutil.compile_globs(include_globs) or nil
    self._exclude_patterns = exclude_globs and strutil.compile_globs(exclude_globs) or nil
    self._follow_symlinks = follow_symlinks or true
    self:_reload()
end

function FileTree:_clear()
    self:_clear_all_monitors()
    self._treebuf:clear_items()
end

function FileTree:_reload()
    self._reload_counter = self._reload_counter + 1
    self._pending_reveal = nil

    local path = self._root
    if not path then
        self:_clear()
        local error_msg = "Error"
        local root_item = {
            id = _error_node_id,
            data = { path = "", name = error_msg, is_dir = false, icon = "⚠", icon_hl = "WarningMsg" }
        }
        self._treebuf:add_item(nil, root_item)
        return
    end

    self._treebuf:remove_item(_error_node_id)

    --self._treebuf:set_header({{path, "Winbar"}})

    if not self._treebuf:have_item(path) then
        local icon, iconhl = self:_get_icon_for_node(path, true, false)
        local root_item = {
            id = path,
            expandable = true,
            expanded = true,
            data = {
                path = path,
                name = vim.fn.fnamemodify(path, ":t"),
                is_dir = true,
                icon = icon,
                icon_hl = iconhl
            }
        }
        self._treebuf:add_item(nil, root_item)
    end

    self:_read_dir(path, self._reload_counter, true)
    if self._pending_selection then
        self:_reveal(self._pending_selection)
        self._pending_selection = nil
    end
end

function FileTree:_on_refresh_by_user()
    self._reload_counter = self._reload_counter + 1
    self:_clear()
    local reload_counter = self._reload_counter
    vim.defer_fn(function()
        if reload_counter == self._reload_counter then
            self:_reload()
        end
    end, 300)
end

function FileTree:_toggle_hidden()
    self._show_hidden = not self._show_hidden
    self:_set_root(self._root)
end

---@private
---@param parent_id string
---@param item keystone.util.TreeBuffer.ItemDef
function FileTree:_upsert_single_item(parent_id, item)
    local root = self._root
    if not root then return end
    local data = item.data ---@type keystone.FileTree.ItemData
    do
        local existing = self._treebuf:get_item(item.id)
        if existing then
            local type_changed = (data.is_dir ~= existing.data.is_dir)
            if not type_changed then
                if data.is_link ~= existing.data.is_link then
                    existing.data.is_link = data.is_link
                    self._treebuf:refresh_item(item.id)
                end
                return -- nothing to do if name did not change
            end
            self._treebuf:remove_item(item.id)
        end
    end
    local siblings = self._treebuf:get_children(parent_id)
    local insert_target_id = nil
    local insert_before = false
    for _, sibling in ipairs(siblings) do
        local sibling_is_dir = sibling.data.is_dir
        local sibling_name = sibling.data.loname
        local should_be_before = false
        if data.is_dir ~= sibling_is_dir then
            should_be_before = data.is_dir -- dirs come before files
        else
            should_be_before = data.loname < sibling_name
        end
        if should_be_before then
            insert_target_id = sibling.id
            insert_before = true
            break
        end
    end
    if insert_target_id then
        self._treebuf:add_sibling(insert_target_id, item, insert_before)
    else
        self._treebuf:add_item(parent_id, item)
    end
end

---@param name string The filename or directory name
---@param is_dir boolean
---@return string icon
---@return string|nil hl_group
function FileTree:_get_icon_for_node(name, is_dir, is_link)
    local icon, icon_hl
    if is_dir then
        icon, icon_hl = "", "Directory"
    elseif not is_link then
        local ext = name:match("%.([^.]+)$") or ""
        icon, icon_hl = icons.get_icon(name, ext, { default = false })
    end
    return icon or "", icon_hl
end

---@param path string
---@param prep_entries keystone.FileTree.PrepareDirEntry[]
---@param callback fun(resolved_entries: keystone.FileTree.ProcessDirEntry[])
function FileTree:_prepare_dir_entries(path, prep_entries, callback)
    local root = self._root
    local resolved = {} ---@type keystone.FileTree.ProcessDirEntry[]
    local pending = #prep_entries
    if pending == 0 or not root then
        callback({})
        return
    end

    ---@type fun(fp:string,name:string,is_dir:boolean,is_link:boolean)
    local process_entry = function(full_path, name, is_dir, is_link)
        if not is_link or self._follow_symlinks then
            local rel = vim.fs.relpath(self._root, full_path)
            if rel and self:_should_include(rel, is_dir) then
                ---@type keystone.FileTree.ProcessDirEntry
                local entry = {
                    name = name,
                    is_dir = is_dir,
                    is_link = is_link,
                }
                table.insert(resolved, entry)
            end
        end
        pending = pending - 1
        if pending == 0 then callback(resolved) end
    end

    local reload_counter = self._reload_counter
    for _, entry in ipairs(prep_entries) do
        local full_path = vim.fs.joinpath(path, entry.name)
        if entry.type == "link" and self._follow_symlinks then
            vim.uv.fs_stat(full_path, function(err, stat)
                vim.schedule(function() -- processing inside libuv callback -> crash
                    if reload_counter ~= self._reload_counter then return end
                    local is_dir = err == nil and stat ~= nil and stat.type == "directory"
                    process_entry(full_path, entry.name, is_dir, true)
                end)
            end)
        else
            process_entry(full_path, entry.name, entry.type == "directory", entry.type == "link")
        end
    end
end

---@param path string
---@param reload_counter number
---@param recursive boolean
function FileTree:_read_dir(path, reload_counter, recursive)
    if reload_counter ~= self._reload_counter then return end


    local item = self._treebuf:get_item(path)
    if not item then return end
    ---@type keystone.FileTree.ItemData
    local data = item.data

    local req_id = (data.childrenload_req_id or 0) + 1
    data.childrenload_req_id = req_id
    data.children_loading = true
    vim.uv.fs_scandir(path, function(err, handle)
        vim.schedule(function() -- get out of the fast event context
            if reload_counter ~= self._reload_counter then return end
            if req_id ~= data.childrenload_req_id then return end
            data.children_loading = false
            local prep_entries = {} ---@type keystone.FileTree.PrepareDirEntry[]
            if handle then
                while true do
                    local name, type = vim.uv.fs_scandir_next(handle)
                    if not name then break end
                    local entry = { name = name, type = type } ---@type keystone.FileTree.PrepareDirEntry
                    table.insert(prep_entries, entry)
                end
            end
            self:_prepare_dir_entries(path, prep_entries, function(resolved_entries)
                if reload_counter ~= self._reload_counter then return end
                if req_id ~= data.childrenload_req_id then return end
                self:_process_dir(path, resolved_entries, err ~= nil)
                if self._pending_reveal then
                    vim.schedule(function()
                        self:_reveal_step()
                    end)
                end
                if recursive then
                    for _, child in ipairs(self._treebuf:get_children(path)) do
                        ---@type keystone.FileTree.ItemData
                        local child_data = child.data
                        local child_path = child_data.path
                        ---@type keystone.FileTree.ItemData
                        if child_data.is_dir then
                            if child.expandable and child.expanded then
                                self:_read_dir(child_path, reload_counter, recursive)
                            end
                        end
                    end
                end
            end)
        end)
    end)
end

---@param entries keystone.FileTree.ProcessDirEntry[]
---@param error_flag boolean
function FileTree:_process_dir(path, entries, error_flag)
    local root = self._root
    if not root then return end
    local parent_item = self._treebuf:get_item(path)
    if not parent_item then return end

    if error_flag then
        parent_item.data.error_flag = true
        self._treebuf:refresh_item(path)
    end
    local new_entries_map = {} ---@type table<string, keystone.FileTree.UpsetSingleItemArgs>
    for _, entry in ipairs(entries) do
        local full_path = vim.fs.joinpath(path, entry.name)
        new_entries_map[full_path] = {
            parent_path = path,
            full_path = full_path,
            name = entry.name,
            loname = entry.name:lower(),
            is_dir = entry.is_dir,
            is_link = entry.is_link,
        }
    end
    local current_children = self._treebuf:get_children(path)
    for _, child in ipairs(current_children) do
        if not new_entries_map[child.id] then
            self._treebuf:remove_item(child.id)
        end
    end

    local children = {} ---@type keystone.util.TreeBuffer.ItemDef[]
    for _, entry in pairs(new_entries_map) do
        local icon, icon_hl = self:_get_icon_for_node(entry.name, entry.is_dir, entry.is_link)
        local expanded = self._pending_expand[entry.full_path]
        if expanded ~= nil then self._pending_expand[entry.full_path] = nil end
        ---@type keystone.util.TreeBuffer.ItemDef
        local child = {
            id = entry.full_path,
            expandable = entry.is_dir,
            expanded = expanded,
            data = {
                path = entry.full_path,
                name = entry.name,
                loname = entry.loname,
                is_dir = entry.is_dir,
                is_link = entry.is_link,
                icon = icon,
                icon_hl = icon_hl
            }
        }
        table.insert(children, child)
    end

    if #current_children > 0 then
        table.sort(children, function(a, b)
            if a.data.is_dir ~= b.data.is_dir then return a.data.is_dir end
            return a.data.loname > b.data.loname -- reverse order
        end)
        for _, child in ipairs(children) do
            local item = self:_upsert_single_item(path, child)
        end
    else
        table.sort(children, function(a, b)
            if a.data.is_dir ~= b.data.is_dir then return a.data.is_dir end
            return a.data.loname < b.data.loname
        end)
        self._treebuf:set_children(path, children)
    end
end

---@param path string
---@param collapse_others boolean?
---@param set_current boolean?
function FileTree:reveal(path, collapse_others, set_current)
    self:_reveal(path, collapse_others, set_current)
end

---@private
---@param path string
---@param collapse_others boolean?
---@param set_current boolean?
function FileTree:_reveal(path, collapse_others, set_current)
    local root = self._root
    if not root or not path or path == "" then return end

    path = vim.fs.normalize(path)
    local rel = vim.fs.relpath(root, path)
    if not rel then return end

    if collapse_others then
        for _, item in ipairs(self._treebuf:get_items()) do
            if item.id ~= root and item.expanded then
                if not vim.startswith(path, item.id) then
                    self._treebuf:collapse(item.id)
                end
            end
        end
    end
    if self._last_revealed_id then
        local old = self._treebuf:get_item(self._last_revealed_id)
        if old then
            old.data.is_current = false
            self._treebuf:refresh_item(old.id)
        end
        self._last_revealed_id = nil
    end

    local parts = rel ~= "" and vim.split(rel, "/", { plain = true }) or {}
    self._pending_reveal = {
        parts = parts,
        idx = 1,
        current = root,
        set_current = set_current or false,
    }

    self:_reveal_step()
end

function FileTree:_reveal_step()
    local state = self._pending_reveal
    if not state then return end

    while true do
        local parent = state.current
        local idx = state.idx

        if idx > #state.parts then
            self._treebuf:set_cursor_by_id(parent)

            if state.set_current then
                local item = self._treebuf:get_item(parent)
                if item then
                    item.data.is_current = true
                    self._treebuf:refresh_item(parent)
                    self._last_revealed_id = parent
                end
            end
            self._pending_reveal = nil
            return
        end

        local next_path = vim.fs.joinpath(parent, state.parts[idx])
        local parent_item = self._treebuf:get_item(parent)
        if not parent_item then
            self._pending_reveal = nil
            return
        end
        if not parent_item.expanded then
            self._treebuf:expand(parent)
        end
        if parent_item.data.children_loading then
            return -- just stop, will resume later
        end
        if not self._treebuf:have_item(next_path) then
            self._pending_reveal = nil
            return
        end
        state.current = next_path
        state.idx = idx + 1
    end
end

---@param collapse_others boolean?
function FileTree:reveal_current_file(collapse_others)
    local buf = vim.api.nvim_get_current_buf()
    if _is_regular_buffer(buf) then
        local path = vim.api.nvim_buf_get_name(buf)
        if path ~= "" then
            self:_reveal(path, collapse_others or false, true)
        end
    end
end

---@param item table The parent or sibling item
---@param as_dir boolean
---@param force_parent boolean?
function FileTree:_create_node(item, as_dir, force_parent)
    local path = item.data.path

    local base_dir
    if force_parent then
        base_dir = vim.fn.fnamemodify(item.data.path, ":h")
    else
        if item.data.is_dir then
            base_dir = item.data.path
        else
            base_dir = vim.fn.fnamemodify(item.data.path, ":h")
        end
    end

    local type_label = as_dir and "directory" or "file"

    local reload_counter = self._reload_counter

    ---@return boolean,string?,string?
    local function check_name(name)
        local root = self._root
        if not root or reload_counter ~= self._reload_counter then
            return false, ("Cannot create %s, tree was reloaded"):format(type_label)
        end
        if not name or name == "" then return false, "Name cannot be empty" end
        local new_path = vim.fn.fnamemodify(vim.fs.joinpath(base_dir, name), ":p")
        if vim.fn.fnamemodify(new_path, ":h") ~= base_dir then return false, "Invalid name" end
        return true, nil, new_path
    end

    inputwin.open({
            prompt = "New " .. type_label .. " name",
            validate = function(name)
                return check_name(name)
            end
        },
        function(name)
            if not name then return end
            local name_ok, name_err, new_path = check_name(name)
            if not name_ok or not new_path then
                vim.notify(name_err or "Invalid name", vim.log.levels.ERROR)
                return
            end
            if as_dir then
                local ok, err = vim.uv.fs_mkdir(new_path, 493) -- 493 is octal 0755
                if ok then
                    self:_read_dir(base_dir, self._reload_counter, false)
                    self:_reveal(new_path)
                else
                    vim.notify(err or "Failed to create directory", vim.log.levels.ERROR)
                end
            else
                local created, err = fsutil.create_file(new_path)
                if created then
                    self:_read_dir(base_dir, self._reload_counter, false)
                    self:_reveal(new_path)
                else
                    vim.notify(err or "Failed to create file", vim.log.levels.ERROR)
                end
            end
        end)
end

---@param item table
function FileTree:_rename_node(item)
    local is_dir = item.data.is_dir
    local old_path = item.data.path
    local old_name = item.data.name
    local parent_dir = vim.fn.fnamemodify(old_path, ":h")

    local reload_counter = self._reload_counter

    ---@param name string
    ---@return boolean, string|nil, string|nil
    local function check_name(name)
        local root = self._root
        if not root or reload_counter ~= self._reload_counter then
            return false, "Cannot change name, tree was reloaded"
        end
        if not name or name == "" then return false, "Name cannot be empty" end
        local new_path = vim.fn.fnamemodify(vim.fs.joinpath(parent_dir, name), ":p")
        local new_parent = vim.fn.fnamemodify(new_path, ":h")
        if new_parent ~= parent_dir then return false, "Invalid name" end
        return true, nil, new_path
    end
    inputwin.open({
            prompt = ("Rename `%s`"):format(old_name),
            default = old_name,
            validate = function(name)
                return check_name(name)
            end
        },
        ---@param new_name string
        function(new_name)
            if not new_name then return end
            local name_ok, name_err, final_path = check_name(new_name)
            if not name_ok or not final_path then
                vim.notify(name_err or "Invalid name", vim.log.levels.ERROR)
                return
            end
            if not self._treebuf:get_item(old_path) then return end
            if old_path == final_path then return end

            local ok, err = fsutil.rename_file(old_path, final_path)
            if ok then
                self:_read_dir(parent_dir, self._reload_counter, false)

                local final_dir = vim.fn.fnamemodify(final_path, ":h")
                if final_dir ~= parent_dir then
                    self:_read_dir(final_dir, self._reload_counter, false)
                end

                self:_reveal(final_path)
            else
                vim.notify("Operation failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
            end
        end)
end

---@private
---@param item keystone.util.TreeBuffer.ItemDef
function FileTree:_show_hover(item)
    local data = item.data ---@type keystone.FileTree.ItemData
    local path = data.path

    local function fmt_size(bytes)
        if bytes < 1024 then return bytes .. " B"
        elseif bytes < 1048576 then return ("%.1f KB"):format(bytes / 1024)
        elseif bytes < 1073741824 then return ("%.1f MB"):format(bytes / 1048576)
        else return ("%.1f GB"):format(bytes / 1073741824) end
    end

    local function perm_str(mode)
        local chars = "rwxrwxrwx"
        local result = ""
        for i = 8, 0, -1 do
            if math.floor(mode / (2 ^ i)) % 2 == 1 then
                result = result .. chars:sub(9 - i, 9 - i)
            else
                result = result .. "-"
            end
        end
        return result
    end

    local function render(stat, link_target)
        vim.schedule(function()
            local type_label = data.is_dir and "Directory" or (data.is_link and "Symlink" or "File")
            local lines = { "# " .. data.name, "" }
            table.insert(lines, "*" .. path .. "*")
            table.insert(lines, "")
            if stat then
                table.insert(lines, "**Type** " .. type_label)
                if data.is_link and link_target then
                    table.insert(lines, "**Target** " .. link_target)
                end
                table.insert(lines, "")
                if not data.is_dir then
                    table.insert(lines, "**Size** " .. fmt_size(stat.size))
                end
                if stat.mtime then
                    local t = os.date("*t", stat.mtime.sec) --[[@as osdate]]
                    table.insert(lines, ("**Modified** %04d-%02d-%02d %02d:%02d"):format(
                        t.year, t.month, t.day, t.hour, t.min))
                end
                table.insert(lines, "**Mode** " .. perm_str(stat.mode % 512))
            else
                table.insert(lines, "*" .. type_label .. "*")
                if data.is_link and link_target then
                    table.insert(lines, "**Target** " .. link_target)
                end
            end

            vim.lsp.util.open_floating_preview(lines, "markdown", {
                border = "rounded",
                focusable = false,
                close_events = { "CursorMoved", "BufHidden", "BufLeave" },
                max_width = 70,
            })
        end)
    end

    vim.uv.fs_stat(path, function(_, stat)
        if data.is_link then
            vim.uv.fs_readlink(path, function(_, target)
                render(stat, target)
            end)
        else
            render(stat, nil)
        end
    end)
end

---@private
--- Toggle the selection state of the item under the cursor.
---@param item keystone.util.TreeBuffer.Item
function FileTree:_toggle_select(item)
    local path = item.data.path
    if path == self._root then return end -- the root is not selectable
    if self._selected[path] then
        self._selected[path] = nil
    else
        self._selected[path] = true
    end
    self._treebuf:refresh_item(path)
end

---@private
--- Collect the items covered by the current visual selection.
---@return keystone.util.TreeBuffer.Item[]
function FileTree:_get_visual_items()
    local winid = self._treebuf:get_winid()
    if winid <= 0 then return {} end

    local start_row = vim.fn.line("v", winid)
    local end_row = vim.fn.line(".", winid)
    if start_row > end_row then
        start_row, end_row = end_row, start_row
    end

    local items = {}
    for row = start_row, end_row do
        local item = self._treebuf:get_item_at_row(row)
        if item then
            items[#items + 1] = item
        end
    end
    return items
end

--- Leave visual mode synchronously so a following blocking prompt sees normal mode.
local function _exit_visual_mode()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
end

---@private
--- Toggle the selection state of every item covered by the current visual
--- selection and exit visual mode.
function FileTree:_visual_select()
    for _, item in ipairs(self:_get_visual_items()) do
        local path = item.data.path
        if path ~= self._root then
            if self._selected[path] then
                self._selected[path] = nil
            else
                self._selected[path] = true
            end
            self._treebuf:refresh_item(path)
        end
    end
    _exit_visual_mode()
end

---@private
--- Collect the currently selected items that still exist, pruning stale paths.
---@return keystone.util.TreeBuffer.Item[]
function FileTree:_get_selected_items()
    local items = {}
    for path in pairs(self._selected) do
        local item = self._treebuf:get_item(path)
        if item then
            items[#items + 1] = item
        else
            self._selected[path] = nil
        end
    end
    return items
end

---@private
--- Clear the whole selection, refreshing the affected lines.
function FileTree:_clear_selection()
    local paths = vim.tbl_keys(self._selected)
    self._selected = {}
    for _, path in ipairs(paths) do
        if self._treebuf:have_item(path) then
            self._treebuf:refresh_item(path)
        end
    end
end

---@private
--- Delete the given items (recursively for directories), pruning any of them
--- from the marked selection. Uses the system trash when available, otherwise
--- deletes permanently.
---@param items keystone.util.TreeBuffer.Item[]
function FileTree:_delete_items(items)
    local targets = {}
    for _, item in ipairs(items) do
        if item.data.path ~= self._root then
            targets[#targets + 1] = item
        end
    end
    if #targets == 0 then return end

    local use_trash = fsutil.has_trash()

    local lines = {}
    for _, item in ipairs(targets) do
        lines[#lines + 1] = "  " .. item.data.path
    end
    local prompt = use_trash and "Move %d item(s) to trash?" or "Permanently delete %d item(s)?"
    local msg = (prompt .. "\n%s"):format(#targets, table.concat(lines, "\n"))

    local reload_counter = self._reload_counter
    uitool.confirm_action(msg, false, function(confirmed)
        if not confirmed then return end
        if reload_counter ~= self._reload_counter then return end

        local dirs_to_refresh = {}
        local failed = 0
        for _, item in ipairs(targets) do
            local path = item.data.path
            if self._treebuf:get_item(path) then
                local removed
                if use_trash then
                    removed = fsutil.trash_path(path)
                else
                    removed = vim.fn.delete(path, "rf") == 0
                end
                if removed then
                    self._selected[path] = nil
                    dirs_to_refresh[vim.fn.fnamemodify(path, ":h")] = true
                else
                    failed = failed + 1
                end
            end
        end

        for dir in pairs(dirs_to_refresh) do
            if self._treebuf:have_item(dir) then
                self:_read_dir(dir, self._reload_counter, false)
            end
        end
        if failed > 0 then
            vim.notify(("Failed to delete %d item(s)"):format(failed), vim.log.levels.ERROR)
        end
    end)
end

---@private
--- Move or copy every selected item into the directory implied by `target_item`
--- (the item itself when it is a directory, otherwise its parent directory).
---@param target_item keystone.util.TreeBuffer.Item
---@param is_copy boolean
function FileTree:_transfer_selected(target_item, is_copy)
    local items = self:_get_selected_items()
    if #items == 0 then
        vim.notify("No items selected", vim.log.levels.WARN)
        return
    end

    local verb = is_copy and "copy" or "move"
    local dest_dir = target_item.data.is_dir
        and target_item.data.path
        or vim.fn.fnamemodify(target_item.data.path, ":h")

    -- Build the list of actual operations, skipping no-ops and illegal ones.
    local ops = {} ---@type {from:string, to:string, name:string}[]
    for _, item in ipairs(items) do
        local from = item.data.path
        local name = item.data.name
        local to = vim.fs.joinpath(dest_dir, name)
        if from == self._root then
            -- never transfer the root
        elseif vim.fn.fnamemodify(from, ":h") == dest_dir then
            -- already in the destination directory; nothing to do
        elseif item.data.is_dir and (dest_dir == from or vim.startswith(dest_dir, from .. "/")) then
            vim.notify(("Cannot %s %s into itself"):format(verb, name), vim.log.levels.WARN)
        elseif fsutil.file_exists(to) then
            vim.notify(("Skipping %s: already exists in destination"):format(name), vim.log.levels.WARN)
        else
            ops[#ops + 1] = { from = from, to = to, name = name }
        end
    end

    if #ops == 0 then return end

    local lines = {}
    for _, op in ipairs(ops) do
        lines[#lines + 1] = "  " .. op.from
    end
    local msg = ("%s %d item(s) to %s?\n%s"):format(
        verb:sub(1, 1):upper() .. verb:sub(2), #ops, dest_dir, table.concat(lines, "\n"))

    local reload_counter = self._reload_counter
    uitool.confirm_action(msg, false, function(confirmed)
        if not confirmed then return end
        if reload_counter ~= self._reload_counter then return end

        local dirs_to_refresh = { [dest_dir] = true }
        local failed = 0
        for _, op in ipairs(ops) do
            if self._treebuf:get_item(op.from) then
                local ok, err
                if is_copy then
                    ok, err = fsutil.copy_path(op.from, op.to)
                else
                    ok, err = fsutil.rename_file(op.from, op.to)
                end
                if ok then
                    dirs_to_refresh[vim.fn.fnamemodify(op.from, ":h")] = true
                else
                    failed = failed + 1
                    vim.notify(("Failed to %s %s: %s"):format(verb, op.name, err or "unknown error"),
                        vim.log.levels.ERROR)
                end
            end
        end

        self:_clear_selection()
        for dir in pairs(dirs_to_refresh) do
            if self._treebuf:have_item(dir) then
                self:_read_dir(dir, self._reload_counter, false)
            end
        end
        if failed == 0 then
            self:_reveal(dest_dir)
        end
    end)
end


return FileTree
