--[[
    FTP Folder Download Patch for KOReader
    =======================================
    Long-press any folder in the FTP browser to download it recursively.
    Settings exposed under:  Settings → AI Slop Settings → FTP Folder Download

    Improvements over base version:
      - Uses MLSD for directory listing (RFC 3659, unambiguous type detection)
        with automatic fallback to LIST if server does not support MLSD
      - File downloads pipe directly to disk via ltn12.sink.file instead of
        buffering the entire file in memory first

    Install as:  <koreader>/patches/2-ftp-folder-download.lua
--]]

local logger = require("logger")
logger.info("[ftp-folder-dl] loading...")

-- ── Settings ──────────────────────────────────────────────────────────────────

local DEFAULTS = {
    enabled     = true,
    on_conflict = "skip",   -- "skip" or "overwrite"
}

local function getCfg()
    return G_reader_settings:readSetting("ftp_folder_dl") or {}
end
local function get(key)
    local cfg = getCfg()
    if cfg[key] ~= nil then return cfg[key] end
    return DEFAULTS[key]
end
local function set(key, value)
    local cfg = getCfg()
    cfg[key] = value
    G_reader_settings:saveSetting("ftp_folder_dl", cfg)
end

-- ── FTP helpers ───────────────────────────────────────────────────────────────

local function parseAddress(address)
    local bare = address:gsub("^ftps?://", "")
    local host, port = bare:match("^(.+):(%d+)$")
    if host then return host, tonumber(port) end
    return bare, nil
end

local function baseParams(host, port, username, password)
    local p = {
        host     = host,
        user     = (username and username ~= "") and username or nil,
        password = (username and username ~= "") and (password or "") or nil,
        type     = "i",
    }
    if port then p.port = port end
    return p
end

-- ── MLSD listing (RFC 3659) ───────────────────────────────────────────────────
-- Returns {name, is_dir} list, or nil if server does not support MLSD.
-- MLSD lines look like:
--   Type=dir;Modify=20250101120000;UNIX.mode=0755; Some Folder Name
--   Type=file;Size=12345;Modify=20250101120000; file.cbz
local function parseMlsd(raw)
    local entries = {}
    for line in (raw or ""):gmatch("[^\r\n]+") do
        -- Split on first space that separates facts from name
        local facts, name = line:match("^([^%s]+)%s+(.+)$")
        if facts and name then
            name = name:match("^%s*(.-)%s*$")
            if name ~= "" and name ~= "." and name ~= ".." then
                local type_val = facts:match("[Tt]ype=([^;]+)")
                if type_val then
                    type_val = type_val:lower()
                    if type_val == "dir" or type_val == "cdir" or type_val == "pdir" then
                        if name ~= "." and name ~= ".." then
                            table.insert(entries, { name = name, is_dir = true })
                        end
                    elseif type_val == "file" or type_val == "os.unix=symlink" then
                        table.insert(entries, { name = name, is_dir = false })
                    end
                end
            end
        end
    end
    return entries
end

local function ftpMlsd(host, port, username, password, path)
    local ltn12      = require("ltn12")
    local socket_ftp = require("socket.ftp")
    if not path:match("/$") then path = path .. "/" end
    local t = {}
    local p = baseParams(host, port, username, password)
    p.path    = path
    p.command = "mlsd"
    p.sink    = ltn12.sink.table(t)
    logger.info("[ftp-folder-dl] MLSD", host, path)
    local ok, err = socket_ftp.get(p)
    if not ok then return nil, err end
    return table.concat(t)
end

-- ── LIST listing (universal fallback) ────────────────────────────────────────
-- Handles Unix long format and Windows IIS format.
local function parseList(raw)
    local entries = {}
    for line in (raw or ""):gmatch("[^\r\n]+") do
        -- Unix long format: drwxr-xr-x 1 owner group size month day time name
        local flag, name = line:match(
            "^([dl%-][rwxsStTx%-]+)%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(.+)$")
        if flag and name then
            name = name:match("^%s*(.-)%s*$")
            if name ~= "" and name ~= "." and name ~= ".." then
                table.insert(entries, { name = name, is_dir = flag:sub(1,1) == "d" })
            end
        else
            -- Windows IIS <DIR>: MM-DD-YY  HH:MMAM/PM  <DIR>  name
            local win_dir = line:match("^%d+%-%d+%-%d+%s+%d+:%d+%a+%s+<DIR>%s+(.+)$")
            if win_dir then
                win_dir = win_dir:match("^%s*(.-)%s*$")
                if win_dir ~= "" and win_dir ~= "." and win_dir ~= ".." then
                    table.insert(entries, { name = win_dir, is_dir = true })
                end
            else
                -- Windows IIS file: MM-DD-YY  HH:MMAM/PM  size  name
                local win_file = line:match("^%d+%-%d+%-%d+%s+%d+:%d+%a+%s+%d+%s+(.+)$")
                if win_file then
                    win_file = win_file:match("^%s*(.-)%s*$")
                    if win_file ~= "" then
                        table.insert(entries, { name = win_file, is_dir = false })
                    end
                end
            end
        end
    end
    return entries
end

local function ftpList(host, port, username, password, path)
    local ltn12      = require("ltn12")
    local socket_ftp = require("socket.ftp")
    if not path:match("/$") then path = path .. "/" end
    local t = {}
    local p = baseParams(host, port, username, password)
    p.path    = path
    p.command = "list"
    p.sink    = ltn12.sink.table(t)
    logger.info("[ftp-folder-dl] LIST", host, path)
    local ok, err = socket_ftp.get(p)
    if not ok then return nil, err end
    return table.concat(t)
end

-- ── Combined listing: MLSD first, fall back to LIST ──────────────────────────
-- Cache whether MLSD works per host so we don't retry failed MLSD every folder
local _mlsd_supported = {}

local function ftpListEntries(host, port, username, password, path)
    local host_key = host .. ":" .. tostring(port)

    if _mlsd_supported[host_key] ~= false then
        local raw, err = ftpMlsd(host, port, username, password, path)
        if raw then
            local entries = parseMlsd(raw)
            _mlsd_supported[host_key] = true
            return entries
        else
            logger.info("[ftp-folder-dl] MLSD not supported, falling back to LIST:", err)
            _mlsd_supported[host_key] = false
        end
    end

    local raw, err = ftpList(host, port, username, password, path)
    if not raw then return nil, err end
    return parseList(raw)
end

-- ── File download: pipe directly to disk ─────────────────────────────────────
local function ftpGetFile(host, port, username, password, remote_path, local_path)
    local ltn12      = require("ltn12")
    local socket_ftp = require("socket.ftp")

    local f, err = io.open(local_path, "wb")
    if not f then
        return false, "cannot open local file: " .. tostring(err)
    end

    local p = baseParams(host, port, username, password)
    p.path = remote_path
    p.sink = ltn12.sink.file(f)  -- pipes chunks directly to disk, f closed by ltn12

    local ok, dl_err = socket_ftp.get(p)
    if not ok then
        -- Clean up partial file on failure
        pcall(function() f:close() end)
        pcall(function() os.remove(local_path) end)
        return false, dl_err
    end
    return true
end

-- ── Recursive folder download ─────────────────────────────────────────────────

local function downloadFolder(host, port, username, password, remote_path, local_path, progress)
    local lfs = require("libs/libkoreader-lfs")
    local ok_count, fail_count = 0, 0

    if not lfs.attributes(local_path, "mode") then lfs.mkdir(local_path) end

    local entries, err = ftpListEntries(host, port, username, password, remote_path)
    if not entries then
        logger.warn("[ftp-folder-dl] listing failed:", remote_path, err)
        return 0, 1
    end

    for _, entry in ipairs(entries) do
        local r_child = remote_path:gsub("/$", "") .. "/" .. entry.name
        local l_child = local_path .. "/" .. entry.name

        if entry.is_dir then
            local a, b = downloadFolder(host, port, username, password, r_child, l_child, progress)
            ok_count = ok_count + a
            fail_count = fail_count + b
        else
            local exists = lfs.attributes(l_child, "mode")
            if exists and get("on_conflict") == "skip" then
                logger.info("[ftp-folder-dl] skipping existing:", entry.name)
                ok_count = ok_count + 1
                if progress then progress(ok_count, fail_count, entry.name, true) end
            else
                logger.info("[ftp-folder-dl] GET", r_child)
                local ok_dl, dl_err = ftpGetFile(host, port, username, password,
                                                  r_child, l_child)
                if ok_dl then
                    ok_count = ok_count + 1
                    if progress then progress(ok_count, fail_count, entry.name, false) end
                else
                    logger.warn("[ftp-folder-dl] GET failed:", r_child, dl_err)
                    fail_count = fail_count + 1
                    if progress then progress(ok_count, fail_count, entry.name, false) end
                end
            end
        end
    end
    return ok_count, fail_count
end

-- ── CloudStorage patch ────────────────────────────────────────────────────────

local function isFolder(item)
    local is_folder =
        (type(item.url) == "string" and item.url:match("/$"))
        or (not item.mandatory or item.mandatory == "")
    if item.mandatory and tostring(item.mandatory):match("%d") then
        is_folder = false
    end
    return is_folder
end

local function doFolderDownload(item, address, username, password)
    local folder_name = item.text:gsub("/$", "")
    local remote_path = (item.url or ("/" .. folder_name)):gsub("/$", "")
    local host, port  = parseAddress(address)
    logger.info("[ftp-folder-dl] hold fired:", folder_name, "host:", host)

    local UIManager   = require("ui/uimanager")
    local ConfirmBox  = require("ui/widget/confirmbox")
    local InfoMessage = require("ui/widget/infomessage")
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")

    local conflict = get("on_conflict")
    local conflict_label = conflict == "skip" and "skip existing" or "overwrite existing"

    UIManager:show(ConfirmBox:new{
        text = ('Download folder "%s"?\n(%s)'):format(folder_name, conflict_label),
        ok_text = "Download",
        ok_callback = function()
            local dl_dir
            local s_ok, cs = pcall(LuaSettings.open, LuaSettings,
                DataStorage:getSettingsDir() .. "/cloudstorage.lua")
            if s_ok and cs then dl_dir = cs:readSetting("download_dir") end
            if not dl_dir or dl_dir == "" then
                dl_dir = G_reader_settings
                    and G_reader_settings:readSetting("lastdir") or "/tmp"
            end

            local local_dest = dl_dir .. "/" .. folder_name
            logger.info("[ftp-folder-dl] downloading to:", local_dest)

            -- Reset MLSD cache for this session so a fresh attempt is made
            _mlsd_supported = {}

            -- Running progress message — updated after each file, no pre-count needed
            local cur_msg
            local function updateProgress(ok_n, fail_n, filename, skipped)
                if cur_msg then UIManager:close(cur_msg) end
                local status = skipped and "skipped" or (fail_n > 0 and "failed" or "saved")
                cur_msg = InfoMessage:new{
                    text = ('Downloading "%s"\n%d saved, %d failed\n%s: %s'):format(
                        folder_name, ok_n, fail_n, status, filename),
                }
                UIManager:show(cur_msg)
                UIManager:forceRePaint()
            end

            -- Show initial message before first file arrives
            cur_msg = InfoMessage:new{
                text = ('Downloading "%s"…'):format(folder_name),
            }
            UIManager:show(cur_msg)
            UIManager:forceRePaint()

            local pok, a, b = xpcall(
                function()
                    return downloadFolder(host, port, username, password,
                                         remote_path, local_dest, updateProgress)
                end,
                function(e)
                    logger.err("[ftp-folder-dl] error:", e,
                        debug and debug.traceback() or "")
                end
            )

            if cur_msg then UIManager:close(cur_msg) end

            if pok then
                UIManager:show(InfoMessage:new{
                    text = ("Done. %d saved, %d failed.\n-> %s"):format(a, b, local_dest),
                    timeout = 6,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = "Download failed – see koreader.log", timeout = 5,
                })
            end
        end,
    })
end

local ok, CloudStorage = pcall(require, "apps/cloudstorage/cloudstorage")
if not ok or not CloudStorage then
    logger.warn("[ftp-folder-dl] CloudStorage not found:", CloudStorage)
    return
end

local _orig_hold = CloudStorage.onMenuHold
function CloudStorage:onMenuHold(item)
    if self.type == "ftp" and item and isFolder(item) and get("enabled") then
        doFolderDownload(item, self.address or "", self.username or "", self.password or "")
        return true
    end
    if _orig_hold then return _orig_hold(self, item) end
end

-- ── AI Slop Settings menu ─────────────────────────────────────────────────────

local FileManagerMenu      = require("apps/filemanager/filemanagermenu")
local FileManagerMenuOrder = require("ui/elements/filemanager_menu_order")

local orig_setUpdateItemTable = FileManagerMenu.setUpdateItemTable
function FileManagerMenu:setUpdateItemTable()
    if type(FileManagerMenuOrder.filemanager_settings) == "table" then
        local found = false
        for _, k in ipairs(FileManagerMenuOrder.filemanager_settings) do
            if k == "ai_slop_settings" then found = true; break end
        end
        if not found then
            table.insert(FileManagerMenuOrder.filemanager_settings, 1, "ai_slop_settings")
        end
    end

    if not self.menu_items.ai_slop_settings then
        self.menu_items.ai_slop_settings = {
            text = "AI Slop Settings",
            sub_item_table = {},
        }
    end

    local already = false
    for _, item in ipairs(self.menu_items.ai_slop_settings.sub_item_table) do
        if item._ftp_folder_dl_entry then already = true; break end
    end

    if not already then
        table.insert(self.menu_items.ai_slop_settings.sub_item_table, {
            _ftp_folder_dl_entry = true,
            text = "FTP Folder Download",
            sub_item_table = {
                {
                    text_func = function()
                        return get("enabled") and "FTP Folder Download: enabled"
                                               or "FTP Folder Download: disabled"
                    end,
                    checked_func = function() return get("enabled") end,
                    callback = function(tmi)
                        set("enabled", not get("enabled"))
                        if tmi then tmi:updateItems() end
                    end,
                },
                {
                    text = "On existing file: Skip",
                    checked_func = function() return get("on_conflict") == "skip" end,
                    callback = function() set("on_conflict", "skip") end,
                },
                {
                    text = "On existing file: Overwrite",
                    checked_func = function() return get("on_conflict") == "overwrite" end,
                    callback = function() set("on_conflict", "overwrite") end,
                },
            },
        })
    end

    orig_setUpdateItemTable(self)
end

logger.info("[ftp-folder-dl] patch applied")
