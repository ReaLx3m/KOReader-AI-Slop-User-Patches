--[[
    FTP Folder Download Patch for KOReader
    =======================================
    Long-press any folder in the FTP browser to download it recursively.
    Settings exposed under:  Settings → AI Slop Settings → FTP Folder Download

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

local function ftpList(host, port, username, password, path)
    local ltn12      = require("ltn12")
    local socket_ftp = require("socket.ftp")
    if not path:match("/$") then path = path .. "/" end
    local t = {}
    local params = {
        host     = host,
        user     = username ~= "" and username or nil,
        password = username ~= "" and password or nil,
        path     = path,
        type     = "i",
        command  = "list",
        sink     = ltn12.sink.table(t),
    }
    if port then params.port = port end
    logger.info("[ftp-folder-dl] LIST", host, path)
    local ok, err = socket_ftp.get(params)
    if not ok then return nil, err end
    return table.concat(t)
end

local function ftpGetFile(host, port, username, password, path)
    local ltn12      = require("ltn12")
    local socket_ftp = require("socket.ftp")
    local t = {}
    local params = {
        host     = host,
        user     = username ~= "" and username or nil,
        password = username ~= "" and password or nil,
        path     = path,
        type     = "i",
        sink     = ltn12.sink.table(t),
    }
    if port then params.port = port end
    local ok, err = socket_ftp.get(params)
    if not ok then return nil, err end
    return table.concat(t)
end

local function parseListing(raw)
    local entries = {}
    for line in (raw or ""):gmatch("[^\r\n]+") do
        -- Unix format: drwxr-xr-x ... name
        local flag, name = line:match(
            "^([dl%-][rwxsStT%-]+)%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(.+)$")
        if name and name ~= "." and name ~= ".." then
            table.insert(entries, { name = name, is_dir = flag:sub(1,1) == "d" })
        else
            -- Windows IIS <DIR>: MM-DD-YY  HH:MMAM/PM  <DIR>  name
            local win_dir = line:match("^%d+%-%d+%-%d+%s+%d+:%d+%a+%s+<DIR>%s+(.+)$")
            if win_dir and win_dir ~= "." and win_dir ~= ".." then
                table.insert(entries, { name = win_dir, is_dir = true })
            else
                -- Windows IIS file: MM-DD-YY  HH:MMAM/PM  size  name
                local win_file = line:match("^%d+%-%d+%-%d+%s+%d+:%d+%a+%s+%d+%s+(.+)$")
                if win_file then
                    table.insert(entries, { name = win_file, is_dir = false })
                end
            end
        end
    end
    return entries
end

local function downloadFolder(host, port, username, password, remote_path, local_path)
    local lfs = require("libs/libkoreader-lfs")
    local ok_count, fail_count = 0, 0

    if not lfs.attributes(local_path, "mode") then lfs.mkdir(local_path) end

    local listing, err = ftpList(host, port, username, password, remote_path)
    if not listing then
        logger.warn("[ftp-folder-dl] LIST failed:", remote_path, err)
        return 0, 1
    end

    for _, entry in ipairs(parseListing(listing)) do
        local r_child = remote_path:gsub("/$", "") .. "/" .. entry.name
        local l_child = local_path .. "/" .. entry.name

        if entry.is_dir then
            local a, b = downloadFolder(host, port, username, password, r_child, l_child)
            ok_count = ok_count + a
            fail_count = fail_count + b
        else
            local exists = lfs.attributes(l_child, "mode")
            if exists and get("on_conflict") == "skip" then
                logger.info("[ftp-folder-dl] skipping existing:", entry.name)
                ok_count = ok_count + 1
            else
                logger.info("[ftp-folder-dl] GET", r_child)
                local content, dl_err = ftpGetFile(host, port, username, password, r_child)
                if content then
                    local f = io.open(l_child, "wb")
                    if f then
                        f:write(content)
                        f:close()
                        ok_count = ok_count + 1
                    else
                        logger.warn("[ftp-folder-dl] write failed:", l_child)
                        fail_count = fail_count + 1
                    end
                else
                    logger.warn("[ftp-folder-dl] GET failed:", r_child, dl_err)
                    fail_count = fail_count + 1
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

            UIManager:show(InfoMessage:new{
                text = ('Downloading "%s"…'):format(folder_name), timeout = 3,
            })
            UIManager:forceRePaint()

            local pok, a, b = xpcall(
                function()
                    return downloadFolder(host, port, username, password,
                                         remote_path, local_dest)
                end,
                function(e)
                    logger.err("[ftp-folder-dl] error:", e,
                        debug and debug.traceback() or "")
                end
            )

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
    -- Inject "ai_slop_settings" into the Settings tab once
    if type(FileManagerMenuOrder.filemanager_settings) == "table" then
        local found = false
        for _, k in ipairs(FileManagerMenuOrder.filemanager_settings) do
            if k == "ai_slop_settings" then found = true; break end
        end
        if not found then
            table.insert(FileManagerMenuOrder.filemanager_settings, 1, "ai_slop_settings")
        end
    end

    -- Create the parent "AI Slop Settings" entry if not already created by another patch
    if not self.menu_items.ai_slop_settings then
        self.menu_items.ai_slop_settings = {
            text = "AI Slop Settings",
            sub_item_table = {},
        }
    end

    -- Guard against duplicate injection
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
                        return get("enabled") and "FTP Folder Download: enabled" or "FTP Folder Download: disabled"
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
                    callback = function()
                        set("on_conflict", "skip")
                    end,
                },
                {
                    text = "On existing file: Overwrite",
                    checked_func = function() return get("on_conflict") == "overwrite" end,
                    callback = function()
                        set("on_conflict", "overwrite")
                    end,
                },
            },
        })
    end

    orig_setUpdateItemTable(self)
end

logger.info("[ftp-folder-dl] patch applied")
