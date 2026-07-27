local M = {}

-- Argument splitting follows Vim's native <f-args> rules (:h <f-args>), so a
-- command line splits exactly the way Neovim's own opts.fargs would:
--
--   Arguments are separated by unescaped whitespace. A backslash escapes the
--   character after it: \<space> (or \<tab>) is that literal whitespace and
--   does not split the argument, \\ is a single backslash, and a backslash
--   before anything else -- including a trailing backslash at end of line --
--   is kept verbatim along with what follows it. Quotes are not special.
--
--     a\ b c   -> a b  and  c        a\\b   -> a\b
--     a\\\ b   -> a\ b               a\nb   -> a\nb
--     \ a      -> " a"               a\     -> a\
--     "a b"    -> "a  and  b"        --p=x\ y -> --p=x y
--
-- Dispatch uses opts.fargs directly; this splitter exists for completion,
-- which is handed a raw command line rather than parsed arguments.
--
---@param str string
---@return string[]
function M.split_args(str)
    local args  = {}
    local chars = nil -- non-nil once the current argument has begun
    local i     = 1
    local len   = #str

    while i <= len do
        local c = str:sub(i, i)
        if c:match("%s") then
            if chars then
                table.insert(args, table.concat(chars))
                chars = nil
            end
            i = i + 1
        elseif c == "\\" then
            local nxt = str:sub(i + 1, i + 1)
            chars = chars or {}
            if nxt == "" or nxt == "\\" then
                table.insert(chars, "\\") -- trailing, or an escaped backslash
                i = i + (nxt == "" and 1 or 2)
            elseif nxt:match("%s") then
                table.insert(chars, nxt) -- escaped whitespace: does not split
                i = i + 2
            else
                table.insert(chars, "\\" .. nxt) -- not an escape: keep both
                i = i + 2
            end
        else
            chars = chars or {}
            table.insert(chars, c)
            i = i + 1
        end
    end

    if chars then table.insert(args, table.concat(chars)) end
    return args
end

---@alias keystone.util.usercmd.subcommand fun(cmd:string,rest:string[],arg_lead:string):string[]

---@alias keystone.util.usercmd.run_fn
---| fun(cmd:string,args:string[],opts:vim.api.keyset.create_user_command.command_args)


---@param subcommand keystone.util.usercmd.subcommand
local function _complete(subcommand, arg_lead, cmd_line)
    local function filter(strs)
        local out = {}
        for _, s in ipairs(strs or {}) do
            if vim.startswith(s, arg_lead) then
                table.insert(out, s)
            end
        end
        return out
    end

    local args = M.split_args(cmd_line)
    if cmd_line:match("%s+$") then
        table.insert(args, ' ')
    end

    local cmd = args[1]
    if #args == 1 then
        return filter(subcommand(cmd, {}, arg_lead))
    elseif #args >= 2 then
        local rest = { unpack(args, 2) }
        rest[#rest] = nil
        return filter(subcommand(cmd, rest, arg_lead))
    end
    return {}
end

---@param cmd string
---@param run_fn keystone.util.usercmd.run_fn
---@param opts vim.api.keyset.create_user_command.command_args
local function _dispatch(cmd, run_fn, opts)
    local ok, err = pcall(run_fn, cmd, opts.fargs, opts)
    if not ok then
        vim.notify(
            "[keystone.util.nvim] " .. cmd .. " command error\n" .. tostring(err),
            vim.log.levels.ERROR
        )
    end
end

---@param cmd string
---@param run_fn keystone.util.usercmd.run_fn
---@param opts {desc:string?,subcommand:keystone.util.usercmd.subcommand?,count:boolean,range:boolean}?
function M.register_user_cmd(cmd, run_fn, opts)
    opts = opts or {}
    vim.api.nvim_create_user_command(cmd, function(cmd_opts)
            _dispatch(cmd, run_fn, cmd_opts)
        end,
        {
            nargs = "*",
            count = opts.count,
            range = opts.range,
            complete = opts.subcommand ~= nil and function(arg_lead, cmd_line, _)
                return _complete(opts.subcommand, arg_lead, cmd_line)
            end or function() return {} end,
            desc = opts.desc,
        })
end

return M
