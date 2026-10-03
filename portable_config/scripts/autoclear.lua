-- autoclear.lua
-- Automatic cache cleanup for mpv
-- Cleans old files from configurable directories on startup or schedule
-- Config: script-opts/autoclear.conf
-- Cross-OS: Windows (forfiles) / Unix (find)

local opts = {
    log_level = "info",
    base_dir = "~~/cache/",
    folders = "logs,shaders_cache,watch_later",
    days = 7,
    delay = 3,
    interval = 0,
    clean_on_quit = false,
    trim_files = "",
    trim_lines = 100,
}

-- Read options from script-opts/autoclear.conf
require("mp.options").read_options(opts, "autoclear")

-- Convert string values from config to proper types
opts.days = tonumber(opts.days) or 7
opts.delay = tonumber(opts.delay) or 3
opts.interval = tonumber(opts.interval) or 0
opts.clean_on_quit = opts.clean_on_quit == true or opts.clean_on_quit == "yes"
opts.trim_lines = tonumber(opts.trim_lines) or 100

-- OS detection (Windows path separator is backslash)
local is_windows = package.config:sub(1, 1) == "\\"

-- Log level filtering (lower number = more verbose)
local LEVELS = {trace=0, debug=1, info=2, warn=3, error=4, off=5}

local function log(level, msg)
    local configured = LEVELS[opts.log_level:lower()] or 2
    local current = LEVELS[level:lower()] or 2
    if current < configured or current >= 5 then return end
    -- Route debug/trace through mp.msg.info so they're visible at msg-level=all=info
    if current <= 2 then
        mp.msg.info(msg)
    elseif current == 3 then
        mp.msg.warn(msg)
    else
        mp.msg.error(msg)
    end
end

local function expand(p)
    local ok, result = pcall(mp.command_native, {"expand-path", p})
    if ok and type(result) == "string" then return result end
    return p
end

-- Resolve folder path:
--   "logs"               -> base_dir .. "logs"
--   "~~/cache/logs"      -> expanded as-is
--   "C:\temp\cache"      -> absolute, used as-is
-- Returns (resolved_path, display_name)
local function resolve_path(folder)
    folder = folder:gsub("^%s+", ""):gsub("%s+$", "")
    local display = folder:match("([^/\\]+)$") or folder
    if folder:match("^~~") then
        return expand(folder), display
    elseif folder:match("^%a:[/\\]") or folder:match("^[/\\]") then
        return folder, display
    else
        return expand(opts.base_dir .. folder), display
    end
end

-- Count files in a directory (cross-OS)
local function count_files(dir)
    local cmd
    if is_windows then
        dir = dir:gsub("/", "\\")
        cmd = 'dir /b /a-d "' .. dir .. '" 2>nul'
    else
        cmd = 'find "' .. dir .. '" -maxdepth 1 -type f 2>/dev/null'
    end
    local f = io.popen(cmd, "r")
    if not f then return 0 end
    local count = 0
    for _ in f:lines() do count = count + 1 end
    f:close()
    return count
end

-- Delete files older than N days (cross-OS)
local function delete_old_files(dir, days)
    dir = dir:gsub("[/\\]+$", "")
    if is_windows then
        dir = dir:gsub("/", "\\")
        os.execute('forfiles /P "' .. dir .. '" /D -' .. days .. ' /C "cmd /c del @path" >nul 2>nul')
    else
        os.execute('find "' .. dir .. '" -maxdepth 1 -type f -mtime +' .. days .. ' -delete 2>/dev/null')
    end
end

-- Trim a file to keep only the last N lines (cross-OS, pure Lua I/O)
local function trim_file(path, display, keep_lines)
    local f = io.open(path, "r")
    if not f then
        log("debug", display .. ": not found, skipping trim")
        return
    end

    local lines = {}
    for line in f:lines() do
        table.insert(lines, line)
    end
    f:close()

    local total = #lines
    if total <= keep_lines then
        log("debug", display .. ": " .. total .. " lines, under limit of " .. keep_lines)
        return
    end

    local removed = total - keep_lines
    local kept = {}
    for i = total - keep_lines + 1, total do
        table.insert(kept, lines[i])
    end

    f = io.open(path, "w")
    if not f then
        log("warn", display .. ": could not open for writing")
        return
    end
    f:write(table.concat(kept, "\n") .. "\n")
    f:close()

    log("info", "Trimmed " .. removed .. " lines from " .. display .. " (kept " .. keep_lines .. " of " .. total .. ")")
end

-- Clean one folder, return number of files deleted
local function clean_folder(folder_name, days)
    local dir, display = resolve_path(folder_name)
    local before = count_files(dir)

    if before == 0 then
        log("debug", display .. ": empty or not found")
        return 0
    end

    delete_old_files(dir, days)
    local after = count_files(dir)
    local deleted = before - after

    if deleted > 0 then
        log("info", "Deleted " .. deleted .. " file" .. (deleted ~= 1 and "s" or "") .. " from " .. display)
    else
        log("debug", display .. ": 0 files older than " .. days .. " days")
    end

    return deleted
end

-- Main cleanup function
local function run_cleanup()
    local folders = {}
    for f in string.gmatch(opts.folders, "[^,]+") do
        f = f:gsub("^%s+", ""):gsub("%s+$", "")
        if f ~= "" then table.insert(folders, f) end
    end

    log("debug", "Starting: folders=[" .. table.concat(folders, ", ") .. "] days=" .. opts.days)

    local total = 0
    local cleaned = {}

    for _, folder in ipairs(folders) do
        local deleted = clean_folder(folder, opts.days)
        total = total + deleted
        if deleted > 0 then
            local _, display = resolve_path(folder)
            table.insert(cleaned, display)
        end
    end

    if total > 0 then
        log("info", "Total: " .. total .. " file" .. (total ~= 1 and "s" or "") .. " deleted from " .. table.concat(cleaned, ", "))
    else
        log("debug", "Nothing to clean")
    end

    -- Trim files by line count (keep only the most recent N lines)
    if opts.trim_files and opts.trim_files ~= "" and opts.trim_lines > 0 then
        for file in string.gmatch(opts.trim_files, "[^,]+") do
            file = file:gsub("^%s+", ""):gsub("%s+$", "")
            if file ~= "" then
                local path, display = resolve_path(file)
                trim_file(path, display, opts.trim_lines)
            end
        end
    end
end

-- Schedule first cleanup after delay
mp.add_timeout(opts.delay, function()
    run_cleanup()
    -- Set up periodic cleanup if interval > 0
    if opts.interval > 0 then
        mp.add_periodic_timer(opts.interval, run_cleanup)
    end
end)

-- Optional: clean on quit
if opts.clean_on_quit then
    mp.register_event("shutdown", run_cleanup)
end
