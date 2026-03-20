--[[
    FTP Download Manager
    ====================
    Long-press any folder in the FTP browser to download it recursively.
    Settings exposed under:  Settings → AI Slop Settings → FTP Download Manager

    Improvements over base version:
      - Uses MLSD for directory listing (RFC 3659, unambiguous type detection)
        with automatic fallback to LIST if server does not support MLSD
      - File downloads pipe directly to disk via ltn12.sink.file instead of
        buffering the entire file in memory first

    Install as:  <koreader>/patches/2-ftp-download-manager.lua
--]]

local logger = require("logger")
logger.info("[ftp-folder-dl] loading...")

-- ── Settings ──────────────────────────────────────────────────────────────────

local DEFAULTS = {
    enabled         = true,
    on_conflict     = "skip",      -- "skip" or "overwrite"
    natural_sort    = true,        -- sort 1,2,10 instead of 1,10,2
    items_per_page  = 10,          -- items shown per page in selection dialog (10-25)
    default_checked  = false,       -- items checked by default in selection dialog
    selection_shrink   = false,      -- shrink long names to fit (default: truncate)
}

local _cfg_cache = nil
local function getCfg()
    if not _cfg_cache then
        _cfg_cache = G_reader_settings:readSetting("ftp_folder_dl") or {}
    end
    return _cfg_cache
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
    _cfg_cache = nil  -- invalidate cache after write
end

-- ── Natural sort ──────────────────────────────────────────────────────────────
-- Splits strings into text/number chunks so "2. Foo" < "10. Foo".

local ffiUtil = require("ffi/util")

local function naturalLess(a, b)
    a, b = a:lower(), b:lower()
    local ia, ib = 1, 1
    while ia <= #a and ib <= #b do
        local da = a:sub(ia):match("^%d+")
        local db = b:sub(ib):match("^%d+")
        if da and db then
            local na, nb = tonumber(da), tonumber(db)
            if na ~= nb then return na < nb end
            ia = ia + #da
            ib = ib + #db
        else
            local ca, cb = a:sub(ia, ia), b:sub(ib, ib)
            if ca ~= cb then return ffiUtil.strcoll(ca, cb) end
            ia = ia + 1
            ib = ib + 1
        end
    end
    return #a < #b
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
                        local size = tonumber(facts:match("[Ss]ize=(%d+)"))
                        table.insert(entries, { name = name, is_dir = false, size = size })
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

-- ── LIST parser (ftpparse port) ──────────────────────────────────────────────
-- Lua port of D.J. Bernstein's ftpparse.c — handles EPLF, UNIX ls (with/without
-- gid), Microsoft FTP Service, Windows NT FTP Server, VMS, WFTPD,
-- NetPresenz (Mac), NetWare, MSDOS.

local _ftpparse_months = {
    jan=0, feb=1, mar=2, apr=3, may=4,  jun=5,
    jul=6, aug=7, sep=8, oct=9, nov=10, dec=11
}

local function ftpParseLine(line)
    if not line or #line < 2 then return nil end
    local first = line:sub(1,1)

    -- EPLF: "+flags\tname"
    if first == "+" then
        local flagtrycwd = false
        local i = 2
        while i <= #line do
            local c = line:sub(i,i)
            if c == "\t" then
                local name = line:sub(i+1):match("^%s*(.-)%s*$")
                if name ~= "" then return { name=name, is_dir=flagtrycwd } end
                return nil
            elseif c == "/" then flagtrycwd = true; i = i+1
            elseif c == "," then i = i+1
            else while i <= #line and line:sub(i,i) ~= "," do i = i+1 end
            end
        end
        return nil
    end

    -- UNIX ls / NetWare / NetPresenz / WFTPD / symlinks
    if first=="b" or first=="c" or first=="d" or first=="l" or
       first=="p" or first=="s" or first=="-" then
        local flagtrycwd = (first=="d" or first=="l")
        -- Tokenize
        local tokens = {}
        for tok in line:gmatch("%S+") do table.insert(tokens, tok) end
        if #tokens < 4 then return nil end
        -- Find month token
        local month_idx
        for i = 3, math.min(8, #tokens) do
            if _ftpparse_months[tokens[i]:lower()] then month_idx=i; break end
        end
        if not month_idx or month_idx+3 > #tokens then return nil end
        -- Find byte position of token (month_idx+3) in original line
        local tok_count, in_space, pos, name_start = 0, true, 1, nil
        while pos <= #line do
            local c = line:sub(pos,pos)
            if c==" " or c=="\t" then in_space=true
            else
                if in_space then
                    tok_count = tok_count+1
                    if tok_count == month_idx+3 then name_start=pos; break end
                    in_space=false
                end
            end
            pos = pos+1
        end
        if not name_start then return nil end
        local name = line:sub(name_start):match("^%s*(.-)%s*$")
        if not name or name=="" or name=="." or name==".." then return nil end
        -- Strip symlink target
        if first=="l" then name = name:match("^(.-)%s+%->%s+.+$") or name end
        -- Strip NetWare leading spaces
        if line:sub(2,2)==" " or line:sub(2,2)=="[" then
            name = name:match("^%s*(.-)%s*$")
        end
        -- Size token is just before the month (month_idx-1)
        local size = not flagtrycwd and tonumber(tokens[month_idx-1]) or nil
        return { name=name, is_dir=flagtrycwd, size=size }
    end

    -- VMS: "NAME.EXT;ver" or "NAME.DIR;ver"
    local semi = line:find(";")
    if semi then
        local name = line:sub(1, semi-1)
        local is_dir = false
        if #name>4 and name:sub(-4):upper()==".DIR" then
            name = name:sub(1,-5); is_dir=true
        end
        if name ~= "" then return { name=name, is_dir=is_dir } end
        return nil
    end

    -- MSDOS / Windows IIS
    if first:match("%d") then
        local dir_name = line:match("^%d+%-%d+%-%d+%s+%d+:%d+%a+%s+<DIR>%s+(.+)$")
        if dir_name then
            dir_name = dir_name:match("^%s*(.-)%s*$")
            if dir_name ~="" and dir_name~="." and dir_name~=".." then
                return { name=dir_name, is_dir=true }
            end
            return nil
        end
        local size_str, file_name = line:match("^%d+%-%d+%-%d+%s+%d+:%d+%a+%s+(%d+)%s+(.+)$")
        if file_name then
            file_name = file_name:match("^%s*(.-)%s*$")
            if file_name ~= "" then
                return { name=file_name, is_dir=false, size=tonumber(size_str) }
            end
        end
        return nil
    end

    return nil
end

local function parseList(raw)
    local entries = {}
    for line in (raw or ""):gmatch("[^\r\n]+") do
        local entry = ftpParseLine(line)
        if entry then table.insert(entries, entry) end
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
local _mlsd_supported = {}

local function ftpListEntriesMlsdList(host, port, username, password, path)
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

-- ── NLST+SIZE listing ─────────────────────────────────────────────────────────
-- Opens one raw TCP connection, authenticates, sends SIZE for every name.
-- SIZE 213 response → file; anything else → directory.

local function ftpSizeProbe(host, port, username, password, path, names)
    local socket  = require("socket")
    local tcp     = socket.tcp()
    tcp:settimeout(15)
    local ok, err = tcp:connect(host, port or 21)
    if not ok then tcp:close(); return nil, err end

    local function recv()
        local line, e = tcp:receive("*l")
        if not line then tcp:close(); return nil, e end
        while line:match("^%d%d%d%-") do
            line = tcp:receive("*l")
            if not line then tcp:close(); return nil end
        end
        return line
    end
    local function cmd(c) tcp:send(c .. "\r\n"); return recv() end

    recv()  -- 220 welcome
    if username and username ~= "" then
        cmd("USER " .. username)
        cmd("PASS " .. (password or ""))
    else
        cmd("USER anonymous"); cmd("PASS guest@")
    end
    cmd("TYPE I")

    local dir_path = path:gsub("/$", "")
    local results  = {}
    for _, name in ipairs(names) do
        local r = cmd("SIZE " .. dir_path .. "/" .. name)
        if r and r:match("^213 ") then
            results[name] = { is_file=true, size=tonumber(r:match("^213 (%d+)")) }
        else
            results[name] = { is_file=false }
        end
    end
    cmd("QUIT"); tcp:close()
    return results
end

local function ftpListEntriesNlstSize(host, port, username, password, path)
    local ltn12      = require("ltn12")
    local socket_ftp = require("socket.ftp")
    if not path:match("/$") then path = path .. "/" end

    local t = {}
    local p = baseParams(host, port, username, password)
    p.path = path; p.command = "nlst"; p.sink = ltn12.sink.table(t)
    local ok, err = socket_ftp.get(p)
    if not ok then return nil, err end

    local names = {}
    for line in (table.concat(t) .. "\n"):gmatch("(.-)\r?\n") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            local name = line:match("([^/]+)/?$") or line
            if name ~= "" then table.insert(names, name) end
        end
    end
    if #names == 0 then return {} end

    local size_results, probe_err = ftpSizeProbe(host, port, username, password,
                                                  path, names)
    if not size_results then
        logger.warn("[ftp-folder-dl] SIZE probe failed:", probe_err,
                    "— falling back to extension heuristic")
        local entries = {}
        for _, name in ipairs(names) do
            table.insert(entries, { name=name, is_dir=not name:match("%.%w+$") })
        end
        return entries
    end

    local entries = {}
    for _, name in ipairs(names) do
        local r = size_results[name]
        table.insert(entries, {
            name   = name,
            is_dir = not r.is_file,
            size   = r.is_file and r.size or nil,
        })
    end
    return entries
end

-- ── Unified listing: MLSD → LIST → NLST+SIZE ────────────────────────────────

local function ftpListEntries(host, port, username, password, path)
    local entries, err = ftpListEntriesMlsdList(host, port, username, password, path)
    if entries and #entries > 0 then return entries end
    logger.info("[ftp-folder-dl] MLSD+LIST returned no results, trying NLST+SIZE:", err)
    return ftpListEntriesNlstSize(host, port, username, password, path)
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
                    if progress then progress(ok_count, fail_count, entry.name, false, entry.size) end
                else
                    logger.warn("[ftp-folder-dl] GET failed:", r_child, dl_err)
                    fail_count = fail_count + 1
                    if progress then progress(ok_count, fail_count, entry.name, false, nil) end
                end
            end
        end
    end
    return ok_count, fail_count
end

-- ── CloudStorage patch ────────────────────────────────────────────────────────

local function isFolder(item)
    if item.type == "folder" then return true end
    if item.type == "file" then return false end
    -- fallback for items without explicit type (original NLST-based listing)
    local is_folder =
        (type(item.url) == "string" and item.url:match("/$"))
        or (not item.mandatory or item.mandatory == "")
    if item.mandatory and tostring(item.mandatory):match("%d") then
        is_folder = false
    end
    return is_folder
end

-- ── Size formatting helper ────────────────────────────────────────────────────

local nbsp = "\194\160"  -- UTF-8 non-breaking space

local function fmtSize(bytes)
    if not bytes then return "" end
    if bytes < 1024 then return (" %d" .. nbsp .. "B"):format(bytes) end
    if bytes < 1024*1024 then return (" %.1f" .. nbsp .. "KB"):format(bytes/1024) end
    if bytes < 1024*1024*1024 then return (" %.1f" .. nbsp .. "MB"):format(bytes/(1024*1024)) end
    return (" %.1f" .. nbsp .. "GB"):format(bytes/(1024*1024*1024))
end

local function fmtSizeRound(bytes)
    if not bytes then return "" end
    if bytes < 1024 then return ("%d B"):format(bytes) end
    if bytes < 1024*1024 then return ("%d KB"):format(math.floor(bytes/1024 + 0.5)) end
    if bytes < 1024*1024*1024 then return ("%d MB"):format(math.floor(bytes/(1024*1024) + 0.5)) end
    return ("%.1f GB"):format(bytes/(1024*1024*1024))
end

-- ── Download helper (shared by folder and file paths) ─────────────────────────

local function getDownloadDir()
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local dl_dir
    local s_ok, cs = pcall(LuaSettings.open, LuaSettings,
        DataStorage:getSettingsDir() .. "/cloudstorage.lua")
    if s_ok and cs then dl_dir = cs:readSetting("download_dir") end
    if not dl_dir or dl_dir == "" then
        dl_dir = G_reader_settings
            and G_reader_settings:readSetting("lastdir") or "/tmp"
    end
    return dl_dir
end

-- ── Selection dialog ──────────────────────────────────────────────────────────

local function showSelectionDialog(host, port, username, password,
                                   parent_remote_path, parent_local_name,
                                   initial_entries, initial_checked, initial_page)
    local UIManager        = require("ui/uimanager")
    local InfoMessage      = require("ui/widget/infomessage")
    local VerticalGroup    = require("ui/widget/verticalgroup")
    local HorizontalGroup  = require("ui/widget/horizontalgroup")
    local HorizontalSpan   = require("ui/widget/horizontalspan")
    local TextWidget       = require("ui/widget/textwidget")
    local Font             = require("ui/font")
    local Screen           = require("device").screen
    local Geom             = require("ui/geometry")
    local MovableContainer = require("ui/widget/container/movablecontainer")
    local FrameContainer   = require("ui/widget/container/framecontainer")
    local CenterContainer  = require("ui/widget/container/centercontainer")
    local Button           = require("ui/widget/button")
    local LineWidget       = require("ui/widget/linewidget")
    local Blitbuffer       = require("ffi/blitbuffer")

    -- Fetch listing if not supplied
    local entries = initial_entries
    if not entries then
        local msg = InfoMessage:new{ text = "Listing folder…" }
        UIManager:show(msg)
        UIManager:forceRePaint()
        local err
        entries, err = ftpListEntries(host, port, username, password, parent_remote_path)
        UIManager:close(msg)
        UIManager:forceRePaint()
        if not entries then
            UIManager:show(InfoMessage:new{
                text = ("Listing failed: %s"):format(tostring(err)), timeout = 5,
            })
            return
        end
        table.sort(entries, function(a, b)
            if a.is_dir ~= b.is_dir then return a.is_dir end
            if get("natural_sort") then return naturalLess(a.name, b.name) end
            return a.name:lower() < b.name:lower()
        end)
    end

    if #entries == 0 then
        UIManager:show(InfoMessage:new{ text = "Folder is empty.", timeout = 3 })
        return
    end

    local checked = initial_checked or {}
    if not initial_checked then
        for i = 1, #entries do checked[i] = get("default_checked") end
    end

    local conflict     = get("on_conflict")
    local conflict_lbl = conflict == "skip" and "skip existing" or "overwrite existing"
    local dl_dir       = getDownloadDir()
    local local_dest   = dl_dir .. "/" .. parent_local_name

    local face       = Font:getFace("cfont", 20)
    local small_face = Font:getFace("cfont", 16)
    local dialog_w   = Screen:getWidth()
    local padding    = Screen:scaleBySize(8)
    local btn_h      = Screen:scaleBySize(48)
    local row_w      = dialog_w - padding * 2

    local per_page   = get("items_per_page")
    local page_count = math.ceil(#entries / per_page)
    local page       = math.max(1, math.min(initial_page or 1, page_count))
    local slots      = math.min(per_page, #entries - (page - 1) * per_page)

    local dialog_widget  -- forward ref


    local size_col_w = Button:new{ text = "999.9 MB", bordersize = 0,
                                   padding = 0, text_font_face = "cfont",
                                   text_font_size = 16 }:getSize().w
    local name_btn_w = row_w - size_col_w
    local text_pad   = Screen:scaleBySize(4)

    local slot_btns, size_btns = {}, {}
    local sep_widgets = {}  -- separator LineWidgets keyed by slot
    local count_btn        -- forward ref, assigned when title row is built

    local row_vg

    local function updateCount()
        if count_btn then
            local n, sz = 0, 0
            for i = 1, #entries do
                if checked[i] then
                    n = n + 1
                    if entries[i].size then sz = sz + entries[i].size end
                end
            end
            local sz_str = sz > 0 and "/" .. fmtSizeRound(sz) or ""
            count_btn:setText(">" .. n .. sz_str, count_btn.width)
            count_btn:refresh()
        end
    end

    local function updateSlots(p)
        local f     = (p - 1) * per_page + 1
        local slots = math.min(per_page, #entries - (p - 1) * per_page)
        local truncate = not get("selection_shrink")
        -- Rebuild vg contents for this page
        while #row_vg > 0 do table.remove(row_vg) end
        slot_btns, size_btns, sep_widgets = {}, {}, {}
        for slot = 1, slots do
            local idx      = f + slot - 1
            local entry    = entries[idx]
            local prefix   = entry and (checked[idx] and "☑ " or "☐ ") or ""
            local icon     = (entry and entry.is_dir) and "▶ " or ""
            local size_str = (entry and not entry.is_dir and entry.size) and fmtSize(entry.size):gsub("^ ", "") or ""
            local name_str = entry and (prefix .. icon .. entry.name) or ""
            local nbtn = Button:new{
                text           = truncate and "" or name_str,
                align          = "left",
                width          = name_btn_w,
                bordersize     = 0,
                padding        = Screen:scaleBySize(4),
                text_font_face = "cfont",
                text_font_size = 20,
                text_font_bold = false,
                callback = function()
                    local real_idx = (page - 1) * per_page + slot
                    if not entries[real_idx] then return end
                    checked[real_idx] = not checked[real_idx]
                    if truncate then
                        -- in-place update: just flip the checkbox prefix
                        local e      = entries[real_idx]
                        local px     = checked[real_idx] and "☑ " or "☐ "
                        local ic     = e.is_dir and "▶ " or ""
                        slot_btns[slot]:setText(px .. ic .. e.name, name_btn_w)
                        slot_btns[slot]:refresh()
                        updateCount()
                        UIManager:setDirty(dialog_widget, "ui")
                    else
                        updateSlots(page)
                    end
                end,
            }
            if truncate then
                nbtn:setText(name_str, name_btn_w)
            end
            local sbtn = Button:new{
                text = size_str, align = "right", width = size_col_w,
                bordersize = 0, padding = 0,
                text_font_face = "cfont", text_font_size = 16, text_font_bold = false,
            }
            slot_btns[slot] = nbtn
            size_btns[slot] = sbtn
            table.insert(row_vg, HorizontalGroup:new{ align = "center", nbtn, sbtn })
            if slot < slots then
                local sep = LineWidget:new{ dimen = Geom:new{ w = row_w, h = Screen:scaleBySize(1) } }
                sep_widgets[slot] = sep
                table.insert(row_vg, sep)
            end
        end
        updateCount()
        UIManager:setDirty(dialog_widget, "ui")
    end

    row_vg = VerticalGroup:new{ allow_mirroring = false }
    updateSlots(page)

    -- Forward refs for nav widgets updated by turnPage
    local btn_prev, btn_next, btn_first, btn_last, page_label_btn

    local function turnPage(new_page)
        page  = new_page
        slots = math.min(per_page, #entries - (page - 1) * per_page)
        updateSlots(page)
        if page > 1 then btn_prev:enable(); btn_first:enable()
        else btn_prev:disable(); btn_first:disable() end
        if page < page_count then btn_next:enable(); btn_last:enable()
        else btn_next:disable(); btn_last:disable() end
        local lbl = ("%d / %d"):format(page, page_count)
        page_label_btn:setText(lbl, page_label_btn.width)
        page_label_btn:refresh()
        btn_prev:refresh()
        btn_next:refresh()
        btn_first:refresh()
        btn_last:refresh()
    end

    local function setPageChecked(state)
        local f = (page - 1) * per_page + 1
        local l = math.min(page * per_page, #entries)
        for i = f, l do checked[i] = state end
        updateSlots(page)
    end

    local function doDownload()
        UIManager:close(dialog_widget)
        UIManager:setDirty(nil, "full")
        UIManager:nextTick(function()

        local selected = {}
        for i, entry in ipairs(entries) do
            if checked[i] then table.insert(selected, entry) end
        end
        if #selected == 0 then
            UIManager:show(InfoMessage:new{ text = "Nothing selected.", timeout = 3 })
            return
        end

        local lfs = require("libs/libkoreader-lfs")
        if not lfs.attributes(local_dest, "mode") then lfs.mkdir(local_dest) end

        local total_ok, total_fail = 0, 0
        local cur_msg

        cur_msg = InfoMessage:new{
            text = ('Downloading "%s"…'):format(parent_local_name),
        }
        UIManager:show(cur_msg)
        UIManager:forceRePaint()

        local function showProgress(filename, size)
            if cur_msg then UIManager:close(cur_msg) end
            cur_msg = InfoMessage:new{
                text = ("%d done, %d failed\n↓ %s%s"):format(
                    total_ok, total_fail, filename, fmtSize(size)),
            }
            UIManager:show(cur_msg)
            UIManager:forceRePaint()
        end

        for _, entry in ipairs(selected) do
            local r_child = parent_remote_path:gsub("/$", "") .. "/" .. entry.name
            local l_child = local_dest .. "/" .. entry.name
            if entry.is_dir then
                local prev_ok, prev_fail = 0, 0
                xpcall(
                    function()
                        downloadFolder(host, port, username, password,
                                       r_child, l_child,
                                       function(ok_n, fail_n, filename, _, size)
                                           total_ok   = total_ok   + (ok_n   - prev_ok)
                                           total_fail = total_fail + (fail_n - prev_fail)
                                           prev_ok, prev_fail = ok_n, fail_n
                                           showProgress(filename, size)
                                       end)
                    end,
                    function(e) logger.err("[ftp-folder-dl]", e) end
                )
            else
                local exists = lfs.attributes(l_child, "mode")
                if exists and get("on_conflict") == "skip" then
                    total_ok = total_ok + 1
                    showProgress(entry.name, entry.size)
                else
                    showProgress(entry.name, entry.size)
                    local ok_dl = ftpGetFile(host, port, username, password, r_child, l_child)
                    if ok_dl then total_ok = total_ok + 1
                    else total_fail = total_fail + 1 end
                end
            end
        end

        if cur_msg then UIManager:close(cur_msg) end
        UIManager:show(InfoMessage:new{
            text = ("Done. %d saved, %d failed.\n-> %s"):format(
                total_ok, total_fail, local_dest),
            timeout = 6,
        })
        end) -- nextTick
    end

    -- Navigation + action buttons
    -- page_label_btn is a borderless Button so we can call setText on it
    page_label_btn = Button:new{
        text      = ("%d / %d"):format(page, page_count),
        width     = Screen:scaleBySize(90),
        bordersize = 0,
        enabled   = page_count > 1,
        callback  = function()
            local InputDialog = require("ui/widget/inputdialog")
            local input_dlg
            input_dlg = InputDialog:new{
                title       = "Go to page",
                input       = tostring(page),
                input_type  = "number",
                buttons     = {{
                    {
                        text     = "Cancel",
                        callback = function() UIManager:close(input_dlg) end,
                    },
                    {
                        text     = "Go",
                        is_enter_default = true,
                        callback = function()
                            local n = tonumber(input_dlg:getInputText())
                            UIManager:close(input_dlg)
                            if n then
                                n = math.max(1, math.min(page_count, math.floor(n)))
                                if n ~= page then turnPage(n) end
                            end
                        end,
                    },
                }},
            }
            UIManager:show(input_dlg)
            input_dlg:onShowKeyboard()
        end,
    }
    btn_first = Button:new{
        text     = "|‹",
        width    = Screen:scaleBySize(44),
        enabled  = page > 1,
        callback = function() turnPage(1) end,
    }
    btn_last = Button:new{
        text     = "›|",
        width    = Screen:scaleBySize(44),
        enabled  = page < page_count,
        callback = function() turnPage(page_count) end,
    }
    btn_prev = Button:new{
        text     = "‹",
        width    = Screen:scaleBySize(44),
        enabled  = page > 1,
        callback = function() turnPage(page - 1) end,
    }
    btn_next = Button:new{
        text     = "›",
        width    = Screen:scaleBySize(44),
        enabled  = page < page_count,
        callback = function() turnPage(page + 1) end,
    }

    local btn_row = HorizontalGroup:new{
        align = "center",
        Button:new{
            text          = "All", width = Screen:scaleBySize(70),
            callback      = function() setPageChecked(true) end,
            hold_callback = function()
                for i = 1, #entries do checked[i] = true end
                updateSlots(page)
            end,
        },
        HorizontalSpan:new{ width = Screen:scaleBySize(4) },
        Button:new{
            text          = "None", width = Screen:scaleBySize(70),
            callback      = function() setPageChecked(false) end,
            hold_callback = function()
                for i = 1, #entries do checked[i] = false end
                updateSlots(page)
            end,
        },
        HorizontalSpan:new{ width = Screen:scaleBySize(10) },
        btn_first,
        HorizontalSpan:new{ width = Screen:scaleBySize(2) },
        btn_prev,
        HorizontalSpan:new{ width = Screen:scaleBySize(2) },
        page_label_btn,
        HorizontalSpan:new{ width = Screen:scaleBySize(2) },
        btn_next,
        HorizontalSpan:new{ width = Screen:scaleBySize(2) },
        btn_last,
        HorizontalSpan:new{ width = Screen:scaleBySize(10) },
        Button:new{
            text = "Download", width = Screen:scaleBySize(140),
            callback = doDownload,
        },
        (function()
            local n, sz = 0, 0
            for i = 1, #entries do
                if checked[i] then
                    n = n + 1
                    if entries[i].size then sz = sz + entries[i].size end
                end
            end
            local sz_str = sz > 0 and "/" .. fmtSizeRound(sz) or ""
            local fixed_w = Screen:scaleBySize(70 + 4 + 70 + 10 + 4*44 + 4*2 + 90 + 10 + 140)
            local count_w = row_w - fixed_w
            count_btn = Button:new{
                text       = ">" .. n .. sz_str,
                width      = count_w,
                align      = "left",
                bordersize = 0,
                padding    = 0,
                face       = small_face,
            }
            return count_btn
        end)(),
    }

    local RightContainer = require("ui/widget/container/rightcontainer")
    local OverlapGroup   = require("ui/widget/overlapgroup")
    local title_h        = Screen:scaleBySize(36)

    local title_row = OverlapGroup:new{
        dimen = Geom:new{ w = dialog_w - padding * 2, h = title_h },
        TextWidget:new{
            text  = ('"%s"  (%s)'):format(parent_local_name, conflict_lbl),
            face  = small_face,
            width = dialog_w - padding * 2 - Screen:scaleBySize(48),
        },
        RightContainer:new{
            dimen = Geom:new{ w = dialog_w - padding * 2, h = title_h },
            [1] = Button:new{
                text      = "✕",
                width     = Screen:scaleBySize(44),
                padding   = Screen:scaleBySize(4),
                bordersize = 0,
                callback  = function()
                    UIManager:close(dialog_widget)
                    UIManager:setDirty(nil, "full")
                end,
            },
        },
    }

    local inner = VerticalGroup:new{
        align = "left",
        FrameContainer:new{
            padding = padding, bordersize = 0,
            [1] = title_row,
        },
        LineWidget:new{ dimen = Geom:new{ w = dialog_w, h = Screen:scaleBySize(1) } },
        FrameContainer:new{
            padding_top    = 0,
            padding_left   = padding,
            padding_right  = padding,
            padding_bottom = 0,
            bordersize = 0,
            [1] = row_vg,
        },
        LineWidget:new{ dimen = Geom:new{ w = dialog_w, h = Screen:scaleBySize(1) } },
        FrameContainer:new{
            padding = Screen:scaleBySize(2), bordersize = 0,
            [1] = btn_row,
        },
    }

    dialog_widget = MovableContainer:new{
        [1] = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            radius     = Screen:scaleBySize(5),
            padding    = 0,
            width      = dialog_w,
            [1]        = inner,
        },
    }

    UIManager:show(dialog_widget)
end

-- ── File hold: show parent folder selection dialog ────────────────────────────

local function doFileDownload(item, address, username, password)
    local file_name   = item.text
    local remote_path = item.url or ("/" .. file_name)
    local host, port  = parseAddress(address)
    logger.info("[ftp-folder-dl] hold fired (file):", file_name, "host:", host)

    -- Derive parent folder path and name from the file's remote path
    local parent_path = remote_path:match("^(.+)/[^/]+$") or "/"
    local parent_name = parent_path:match("([^/]+)/?$") or parent_path

    showSelectionDialog(host, port, username, password,
                        parent_path, parent_name, nil)
end

-- ── Folder hold: show selection dialog ────────────────────────────────────────

local function doFolderDownload(item, address, username, password)
    local folder_name = item.text:gsub("^▶ ", ""):gsub("/$", "")
    local remote_path = (item.url or ("/" .. folder_name)):gsub("/$", "")
    local host, port  = parseAddress(address)
    logger.info("[ftp-folder-dl] hold fired (folder):", folder_name, "host:", host)

    showSelectionDialog(host, port, username, password,
                        remote_path, folder_name, nil)
end

local ok, CloudStorage = pcall(require, "apps/cloudstorage/cloudstorage")
if not ok or not CloudStorage then
    logger.warn("[ftp-folder-dl] CloudStorage not found:", CloudStorage)
    return
end

local _orig_hold = CloudStorage.onMenuHold
function CloudStorage:onMenuHold(item)
    if self.type == "ftp" and item and get("enabled") then
        if isFolder(item) then
            doFolderDownload(item, self.address or "", self.username or "", self.password or "")
            return true
        else
            doFileDownload(item, self.address or "", self.username or "", self.password or "")
            return true
        end
    end
    if _orig_hold then return _orig_hold(self, item) end
end

-- ── FtpApi browser listing patch ─────────────────────────────────────────────
-- Browser listing using unified MLSD → LIST → NLST+SIZE chain.

local ok_ftpapi, FtpApi = pcall(require, "apps/cloudstorage/ftpapi")
if ok_ftpapi and FtpApi then
    local DocumentRegistry = require("document/documentregistry")
    local _browser_mlsd_ok = {}  -- per-host MLSD support cache

    local function urldecode(s)
        if not s then return nil end
        return s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    end

    local function buildBrowserResult(entries, folder_path)
        if folder_path == "/" then folder_path = "" end
        local folders, files = {}, {}
        for _, entry in ipairs(entries) do
            if entry.is_dir then
                table.insert(folders, {
                    text = "▶ " .. entry.name,
                    url  = folder_path .. "/" .. entry.name,
                    type = "folder",
                })
            else
                if DocumentRegistry:hasProvider(entry.name)
                        or G_reader_settings:isTrue("show_unsupported") then
                    table.insert(files, {
                        text      = entry.name,
                        mandatory = entry.size and fmtSize(entry.size):gsub("^ ", "") or nil,
                        url  = folder_path .. "/" .. entry.name,
                        type = "file",
                    })
                end
            end
        end
        if get("natural_sort") then
            local sort_fn = function(a, b) return naturalLess(a.text, b.text) end
            table.sort(folders, sort_fn)
            table.sort(files, sort_fn)
        end
        local result = {}
        for _, item in ipairs(folders) do table.insert(result, item) end
        for _, item in ipairs(files)   do table.insert(result, item) end
        return result
    end

    function FtpApi:listFolder(address_path, folder_path)
        local url_module = require("socket.url")
        local parsed  = url_module.parse(address_path)
        local host    = parsed.host
        local port    = parsed.port and tonumber(parsed.port) or nil
        local user    = urldecode(parsed.user)
        local pass    = urldecode(parsed.password)
        local path    = parsed.path or "/"

        -- MLSD → LIST → NLST+SIZE unified chain
        local host_key = host .. ":" .. tostring(port)
        if _browser_mlsd_ok[host_key] ~= false then
            local raw, err = ftpMlsd(host, port, user, pass, path)
            if raw then
                _browser_mlsd_ok[host_key] = true
                return buildBrowserResult(parseMlsd(raw), folder_path)
            else
                logger.info("[ftp-folder-dl] browser MLSD failed, trying LIST:", err)
                _browser_mlsd_ok[host_key] = false
            end
        end
        local raw, err = ftpList(host, port, user, pass, path)
        if raw then
            local entries = parseList(raw)
            if #entries > 0 then
                return buildBrowserResult(entries, folder_path)
            end
        end
        logger.info("[ftp-folder-dl] browser MLSD+LIST failed, trying NLST+SIZE:", err)
        local ltn12      = require("ltn12")
        local socket_ftp = require("socket.ftp")
        local t = {}
        local p = baseParams(host, port, user, pass)
        p.path = path:match("/$") and path or (path .. "/")
        p.command = "nlst"; p.sink = ltn12.sink.table(t)
        local nlst_ok, nlst_err = socket_ftp.get(p)
        if nlst_ok == nil then
            logger.warn("[ftp-folder-dl] browser NLST failed:", nlst_err)
            return {}
        end
        local names = {}
        for line in (table.concat(t) .. "\n"):gmatch("(.-)\r?\n") do
            line = line:match("^%s*(.-)%s*$")
            if line ~= "" then
                local name = line:match("([^/]+)/?$") or line
                if name ~= "" then table.insert(names, name) end
            end
        end
        if #names == 0 then return {} end
        local size_results, probe_err = ftpSizeProbe(host, port, user, pass, path, names)
        if not size_results then
            logger.warn("[ftp-folder-dl] browser SIZE probe failed:", probe_err)
            size_results = {}
            for _, name in ipairs(names) do
                size_results[name] = { is_file=name:match("%.%w+$") ~= nil }
            end
        end
        local entries = {}
        for _, name in ipairs(names) do
            local r = size_results[name]
            table.insert(entries, { name=name, is_dir=not r.is_file, size=r.size })
        end
        return buildBrowserResult(entries, folder_path)
    end
else
    logger.warn("[ftp-folder-dl] FtpApi not found, browser listing patch skipped")
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
            text = "FTP Download Manager",
            sub_item_table = {
                {
                    text_func = function()
                        return get("enabled") and "FTP Download Manager: enabled"
                                               or "FTP Download Manager: disabled"
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
                {
                    text = "FTP browser: natural sort (1, 2, 10)",
                    checked_func = function() return get("natural_sort") end,
                    callback = function() set("natural_sort", not get("natural_sort")) end,
                },
                {
                    text = "Selection dialog: shrink long names to fit",
                    checked_func = function() return get("selection_shrink") end,
                    callback = function() set("selection_shrink", not get("selection_shrink")) end,
                },
                {
                    text = "Selection dialog: items checked by default",
                    checked_func = function() return get("default_checked") end,
                    callback = function() set("default_checked", not get("default_checked")) end,
                },
                {
                    text = "Items per page in selection dialog",
                    callback = function()
                        local SpinWidget = require("ui/widget/spinwidget")
                        local UIManager  = require("ui/uimanager")
                        local spin = SpinWidget:new{
                            title_text  = "Items per page",
                            value       = get("items_per_page"),
                            value_min   = 10,
                            value_max   = 25,
                            value_step  = 1,
                            ok_text     = "Set",
                            callback    = function(spin_widget)
                                set("items_per_page", spin_widget.value)
                            end,
                        }
                        UIManager:show(spin)
                    end,
                },
            },
        })
    end

    orig_setUpdateItemTable(self)
end

logger.info("[ftp-folder-dl] patch applied")
