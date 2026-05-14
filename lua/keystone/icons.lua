---@class keystone.icon.Data
---@field icon string
---@field color string
---@field name string

---@class keystone.icon.Module
---@field ready boolean
---@field native boolean
---@field devicons table|nil
---@field icons table<string, keystone.icon.Data>
---@field filenames table<string, keystone.icon.Data>
local M = {}

local _ready = false
local _devicons = nil
local _extensions = {}
local _filenames = {}

---@param group string
---@param color string
---@return nil
local function _set_hl(group, color)
    vim.api.nvim_set_hl(0, group, {
        fg = color,
    })
end

---@return nil
local function _init_builtins()
    _extensions = {
        lua = {
            icon = "",
            color = "#51A0CF",
            name = "Lua",
        },
        js = {
            icon = "",
            color = "#cbcb41",
            name = "Js",
        },
        ts = {
            icon = "",
            color = "#519aba",
            name = "Ts",
        },
        jsx = {
            icon = "",
            color = "#20c2e3",
            name = "Jsx",
        },
        tsx = {
            icon = "",
            color = "#1354bf",
            name = "Tsx",
        },
        json = {
            icon = "",
            color = "#cbcb41",
            name = "Json",
        },
        md = {
            icon = "",
            color = "#519aba",
            name = "Markdown",
        },
        vim = {
            icon = "",
            color = "#019833",
            name = "Vim",
        },
        py = {
            icon = "",
            color = "#3572A5",
            name = "Py",
        },
        rs = {
            icon = "",
            color = "#dea584",
            name = "Rust",
        },
        go = {
            icon = "",
            color = "#519aba",
            name = "Go",
        },
        c = {
            icon = "",
            color = "#599eff",
            name = "C",
        },
        cpp = {
            icon = "",
            color = "#519aba",
            name = "Cpp",
        },
        h = {
            icon = "",
            color = "#a074c4",
            name = "Header",
        },
        html = {
            icon = "",
            color = "#e34c26",
            name = "Html",
        },
        css = {
            icon = "",
            color = "#563d7c",
            name = "Css",
        },
        sh = {
            icon = "",
            color = "#4d5a5e",
            name = "Sh",
        },
        yml = {
            icon = "",
            color = "#6d8086",
            name = "Yml",
        },
        yaml = {
            icon = "",
            color = "#6d8086",
            name = "Yaml",
        },
        toml = {
            icon = "",
            color = "#6d8086",
            name = "Toml",
        },
        lock = {
            icon = "󰌾",
            color = "#bbbbbb",
            name = "Lock",
        },
    }

    _filenames = {
        ["Makefile"] = {
            icon = "",
            color = "#6d8086",
            name = "Makefile",
        },
        ["makefile"] = {
            icon = "",
            color = "#6d8086",
            name = "Makefile",
        },
        ["CMakeLists.txt"] = {
            icon = "",
            color = "#DCE3EB",
            name = "CMake",
        },
        ["cmake_install.cmake"] = {
            icon = "",
            color = "#DCE3EB",
            name = "CMake",
        },
        ["CMakeCache.txt"] = {
            icon = "",
            color = "#DCE3EB",
            name = "CMake",
        },
        [".gitignore"] = {
            icon = "",
            color = "#EA7055",
            name = "GitIgnore",
        },
        [".gitattributes"] = {
            icon = "",
            color = "#EA7055",
            name = "GitAttributes",
        },
        [".gitmodules"] = {
            icon = "",
            color = "#EA7055",
            name = "GitModules",
        },
        ["Dockerfile"] = {
            icon = "󰡨",
            color = "#458ee6",
            name = "Dockerfile",
        },
        ["docker-compose.yml"] = {
            icon = "󰡨",
            color = "#458ee6",
            name = "DockerCompose",
        },
        ["docker-compose.yaml"] = {
            icon = "󰡨",
            color = "#458ee6",
            name = "DockerCompose",
        },
        [".env"] = {
            icon = "",
            color = "#faf743",
            name = "Env",
        },
        ["package.json"] = {
            icon = "",
            color = "#cb3837",
            name = "PackageJson",
        },
        ["package-lock.json"] = {
            icon = "",
            color = "#cb3837",
            name = "PackageLock",
        },
        ["tsconfig.json"] = {
            icon = "",
            color = "#519aba",
            name = "TsConfig",
        },
        ["Cargo.toml"] = {
            icon = "",
            color = "#dea584",
            name = "Cargo",
        },
        ["Cargo.lock"] = {
            icon = "",
            color = "#dea584",
            name = "CargoLock",
        },
        ["go.mod"] = {
            icon = "",
            color = "#519aba",
            name = "GoMod",
        },
        ["go.sum"] = {
            icon = "",
            color = "#519aba",
            name = "GoSum",
        },
        ["README.md"] = {
            icon = "",
            color = "#519aba",
            name = "Readme",
        },
        ["LICENSE"] = {
            icon = "",
            color = "#d0bf41",
            name = "License",
        },
        ["init.lua"] = {
            icon = "",
            color = "#51A0CF",
            name = "InitLua",
        },
    }

    for _, icon in pairs(_extensions) do
        _set_hl("KeystoneIcons" .. icon.name, icon.color)
    end

    for _, icon in pairs(_filenames) do
        _set_hl("KeystoneIcons" .. icon.name, icon.color)
    end
end

---@return nil
local function _init()
    if _ready then
        return
    end

    local ok, devicons = pcall(require, "nvim-web-devicons")

    if ok then
        _devicons = devicons
    else
        _init_builtins()
    end

    _set_hl("KeystoneIconsDefault", "#6d8086")

    _ready = true
end

---@param filename? string
---@param extension? string
---@param opts? table
---@return string, string
function M.get_icon(filename, extension, opts)
    if not _ready then
        _init()
    end

    if _devicons then
        return _devicons.get_icon(filename, extension, opts)
    end

    if filename then
        local fileicon = _filenames[filename]
        if fileicon then
            return fileicon.icon, "KeystoneIcons" .. fileicon.name
        end
    end

    local ext = extension

    if not ext and filename then
        ext = filename:match("%.([^.]+)$")
    end

    if not ext then
        return "", "KeystoneIconsDefault"
    end

    local icon = _extensions[ext]

    if not icon then
        return "", "KeystoneIconsDefault"
    end

    return icon.icon, "KeystoneIcons" .. icon.name
end

return M
