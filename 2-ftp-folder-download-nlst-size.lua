--[[
    FTP Folder Download Patch for KOReader (NLST+SIZE version)
    ===========================================================
    Long-press any folder or file in the FTP browser to open a selection dialog
    for downloading individual files or entire folders recursively.
    Settings exposed under:  Settings → AI Slop Settings → FTP Folder Download

    Uses NLST for directory listing, then probes each entry with SIZE to
    reliably determine if it is a file or directory — works correctly with
    dotted folder names. One extra round-trip per entry vs pure NLST.
    File downloads pipe directly to disk via ltn12.sink.file.

    Install as:  <koreader>/patches/2-ftp-folder-download-nlst-size.lua
--]]

local logger = require("logger")
logger.info("[ftp-folder-dl] loading...")

-- ── Settings ──────────────────────────────────────────────────────────────────

local DEFAULTS = {
    enabled        = true,
    on_conflict    = "skip",   -- "skip" or "overwrite"
    natural_sort   = true,     -- sort 1,2,10 instead of 1,10,2
    items_per_page = 10,       -- items shown per page in selection dialog (10-25)
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

-- ── Natural sort ──────────────────────────────────────────────────────────────
-- Splits strings into text/number chunks so "2. Foo" < "10. Foo".

local function naturalLess(a, b)
    local ffiUtil = require("ffi/util")
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

-- ── Raw FTP control channel for SIZE probing ─────────────────────────────────
-- Opens one TCP connection, authenticates, probes all names, closes.
-- Returns a table of { name = true/false (is_file) } keyed by name.

local function ftpSizeProbe(host, port, username, password, path, names)
    local socket = require("socket")
    local tcp = socket.tcp()
    tcp:settimeout(15)

    local ftp_port = port or 21
    local ok, err = tcp:connect(host, ftp_port)
    if not ok then tcp:close(); return nil, err end

    local function recv()
        local line, e = tcp:receive("*l")
        if not line then tcp:close(); return nil, e end
        -- Multi-line responses: keep reading until line starts with "NNN "
        while line:match("^%d%d%d%-") do
            line = tcp:receive("*l")
            if not line then tcp:close(); return nil end
        end
        return line
    end

    local function cmd(c)
        tcp:send(c .. "\r\n")
        return recv()
    end

    -- Handshake
    recv()  -- 220 welcome
    if username and username ~= "" then
        cmd("USER " .. username)
        cmd("PASS " .. (password or ""))
    else
        cmd("USER anonymous")
        cmd("PASS guest@")
    end
    cmd("TYPE I")

    -- Probe each name
    local results = {}
    local dir_path = path:gsub("/$", "")
    for _, name in ipairs(names) do
        local r = cmd("SIZE " .. dir_path .. "/" .. name)
        -- 213 = file size returned; anything else = not a file (directory)
        results[name] = r and r:match("^213 ") ~= nil
    end

    cmd("QUIT")
    tcp:close()
    return results
end

-- ── Directory listing for download traversal (NLST+SIZE) ─────────────────────
-- NLST returns bare names; SIZE on each entry determines file vs directory:
-- SIZE succeeds (213) → file; anything else → directory.

local function ftpListEntries(host, port, username, password, path)
    local ltn12      = require("ltn12")
    local socket_ftp = require("socket.ftp")
    if not path:match("/$") then path = path .. "/" end

    -- Step 1: get names via NLST
    local t = {}
    local p = baseParams(host, port, username, password)
    p.path    = path
    p.command = "nlst"
    p.sink    = ltn12.sink.table(t)

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

    -- Step 2: probe all names via SIZE on a single control connection
    local size_results, probe_err = ftpSizeProbe(host, port, username, password,
                                                  path, names)
    if not size_results then
        -- SIZE probing failed entirely — fall back to extension heuristic
        logger.warn("[ftp-folder-dl] SIZE probe failed:", probe_err,
                    "— falling back to extension heuristic")
        local entries = {}
        for _, name in ipairs(names) do
            table.insert(entries, {
                name   = name,
                is_dir = not name:match("%.%w+$"),
            })
        end
        return entries
    end

    local entries = {}
    for _, name in ipairs(names) do
        table.insert(entries, { name = name, is_dir = not size_results[name] })
    end
    return entries
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

local function runDownloadFolder(host, port, username, password,
                                 remote_path, local_dest, label)
    local UIManager   = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")

    local cur_msg
    local function updateProgress(ok_n, fail_n, filename, skipped)
        if cur_msg then UIManager:close(cur_msg) end
        local status = skipped and "skipped" or (fail_n > 0 and "failed" or "saved")
        cur_msg = InfoMessage:new{
            text = ('Downloading "%s"\n%d saved, %d failed\n%s: %s'):format(
                label, ok_n, fail_n, status, filename),
        }
        UIManager:show(cur_msg)
        UIManager:forceRePaint()
    end

    cur_msg = InfoMessage:new{ text = ('Downloading "%s"…'):format(label) }
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
end

local function runDownloadFile(host, port, username, password,
                               remote_path, local_path, label)
    local UIManager   = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local lfs         = require("libs/libkoreader-lfs")

    -- ensure parent dir exists
    local parent = local_path:match("^(.+)/[^/]+$")
    if parent and not lfs.attributes(parent, "mode") then lfs.mkdir(parent) end

    local exists = lfs.attributes(local_path, "mode")
    if exists and get("on_conflict") == "skip" then
        UIManager:show(InfoMessage:new{
            text = ('Skipped (already exists):\n%s'):format(label), timeout = 4,
        })
        return
    end

    local msg = InfoMessage:new{ text = ('Downloading "%s"…'):format(label) }
    UIManager:show(msg)
    UIManager:forceRePaint()

    local ok_dl, err = ftpGetFile(host, port, username, password, remote_path, local_path)

    UIManager:close(msg)
    if ok_dl then
        UIManager:show(InfoMessage:new{
            text = ("Saved:\n%s"):format(local_path), timeout = 5,
        })
    else
        UIManager:show(InfoMessage:new{
            text = ("Download failed: %s"):format(tostring(err)), timeout = 5,
        })
    end
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
        for i = 1, #entries do checked[i] = true end
    end

    local conflict     = get("on_conflict")
    local conflict_lbl = conflict == "skip" and "skip existing" or "overwrite existing"
    local dl_dir       = getDownloadDir()
    local local_dest   = dl_dir .. "/" .. parent_local_name

    local face       = Font:getFace("cfont", 20)
    local small_face = Font:getFace("cfont", 16)
    local dialog_w   = Screen:getWidth()
    local padding    = Screen:scaleBySize(8)
    local row_h      = Screen:scaleBySize(44)
    local btn_h      = Screen:scaleBySize(48)
    local row_w      = dialog_w - padding * 2

    local per_page   = get("items_per_page")
    local page_count = math.ceil(#entries / per_page)
    local page       = math.max(1, math.min(initial_page or 1, page_count))

    local dialog_widget  -- forward ref

    -- All/None still need a full rebuild since every button text changes at once.
    local function rebuild(new_page)
        UIManager:close(dialog_widget)
        UIManager:nextTick(function()
            showSelectionDialog(host, port, username, password,
                                parent_remote_path, parent_local_name,
                                entries, checked, new_page or page)
        end)
    end

    -- Always create exactly per_page button slots. On page turn we only call
    -- setText+refresh on each slot — no structural changes to the widget tree,
    -- so no full screen refresh is triggered.
    local slot_btns = {}  -- slot_btns[slot] where slot is 1..per_page
    local btns = {}       -- btns[global_idx] for item toggle callbacks

    local function updateSlots(p)
        local f = (p - 1) * per_page + 1
        for slot = 1, per_page do
            local idx   = f + slot - 1
            local entry = entries[idx]
            local btn   = slot_btns[slot]
            if entry then
                local prefix = checked[idx] and "☑ " or "☐ "
                local icon   = entry.is_dir and "▶ " or ""
                btn:setText(prefix .. icon .. entry.name, btn.width)
                btn.enabled = true
                btns[idx] = btn
            else
                btn:setText("", btn.width)
                btn.enabled = false
            end
            btn:refresh()
        end
    end

    -- Build the fixed slot buttons
    local row_vg = VerticalGroup:new{ allow_mirroring = false }
    for slot = 1, per_page do
        local btn = Button:new{
            text       = "",
            align      = "left",
            width      = row_w,
            bordersize = 0,
            padding    = Screen:scaleBySize(4),
            callback   = function()
                local idx = (page - 1) * per_page + slot
                if not entries[idx] then return end
                checked[idx] = not checked[idx]
                local entry      = entries[idx]
                local new_prefix = checked[idx] and "☑ " or "☐ "
                local icon       = entry.is_dir and "▶ " or ""
                slot_btns[slot]:setText(new_prefix .. icon .. entry.name, slot_btns[slot].width)
                slot_btns[slot]:refresh()
            end,
        }
        slot_btns[slot] = btn
        table.insert(row_vg, btn)
    end

    -- Forward refs for nav widgets updated by turnPage
    local btn_prev, btn_next, page_label_btn

    local function turnPage(new_page)
        page = new_page
        updateSlots(page)
        if page > 1 then btn_prev:enable() else btn_prev:disable() end
        if page < page_count then btn_next:enable() else btn_next:disable() end
        local lbl = page_count > 1 and ("%d / %d"):format(page, page_count) or ""
        page_label_btn:setText(lbl, page_label_btn.width)
        page_label_btn:refresh()
        btn_prev:refresh()
        btn_next:refresh()
    end

    -- Populate first page
    updateSlots(page)

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

        local function showProgress(filename)
            if cur_msg then UIManager:close(cur_msg) end
            cur_msg = InfoMessage:new{
                text = ("%d done, %d failed\n%s"):format(total_ok, total_fail, filename),
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
                                       function(ok_n, fail_n, filename)
                                           total_ok   = total_ok   + (ok_n   - prev_ok)
                                           total_fail = total_fail + (fail_n - prev_fail)
                                           prev_ok, prev_fail = ok_n, fail_n
                                           showProgress(filename)
                                       end)
                    end,
                    function(e) logger.err("[ftp-folder-dl]", e) end
                )
            else
                local exists = lfs.attributes(l_child, "mode")
                if exists and get("on_conflict") == "skip" then
                    total_ok = total_ok + 1
                else
                    local ok_dl = ftpGetFile(host, port, username, password, r_child, l_child)
                    if ok_dl then total_ok = total_ok + 1
                    else total_fail = total_fail + 1 end
                end
                showProgress(entry.name)
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
        text      = page_count > 1 and ("%d / %d"):format(page, page_count) or "",
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
    local btn_first = Button:new{
        text     = "|‹",
        width    = Screen:scaleBySize(44),
        enabled  = page > 1,
        callback = function() turnPage(1) end,
    }
    local btn_last = Button:new{
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

    -- Also update first/last enabled state on page turn
    local orig_turnPage = turnPage
    turnPage = function(new_page)
        orig_turnPage(new_page)
        if page > 1 then btn_first:enable() else btn_first:disable() end
        if page < page_count then btn_last:enable() else btn_last:disable() end
        btn_first:refresh()
        btn_last:refresh()
    end

    local function setPageChecked(state)
        local f = (page - 1) * per_page + 1
        local l = math.min(page * per_page, #entries)
        for i = f, l do checked[i] = state end
        UIManager:nextTick(function()
            updateSlots(page)
            for slot = 1, per_page do slot_btns[slot]:refresh() end
        end)
    end

    local btn_row = HorizontalGroup:new{
        align = "center",
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
            text          = "All", width = Screen:scaleBySize(50),
            callback      = function() setPageChecked(true) end,
            hold_callback = function()
                for i = 1, #entries do checked[i] = true end
                UIManager:nextTick(function()
                    updateSlots(page)
                    for slot = 1, per_page do slot_btns[slot]:refresh() end
                end)
            end,
        },
        HorizontalSpan:new{ width = Screen:scaleBySize(4) },
        Button:new{
            text          = "None", width = Screen:scaleBySize(70),
            callback      = function() setPageChecked(false) end,
            hold_callback = function()
                for i = 1, #entries do checked[i] = false end
                UIManager:nextTick(function()
                    updateSlots(page)
                    for slot = 1, per_page do slot_btns[slot]:refresh() end
                end)
            end,
        },
        HorizontalSpan:new{ width = Screen:scaleBySize(10) },
        Button:new{
            text = "Download", width = Screen:scaleBySize(140),
            callback = doDownload,
        },
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
            padding = padding, bordersize = 0,
            [1] = row_vg,
        },
        LineWidget:new{ dimen = Geom:new{ w = dialog_w, h = Screen:scaleBySize(1) } },
        FrameContainer:new{
            padding = padding, bordersize = 0,
            [1] = CenterContainer:new{
                dimen = Geom:new{ w = dialog_w - padding * 2, h = btn_h },
                [1]   = btn_row,
            },
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
-- Replaces NLST with NLST+SIZE so dotted folder names are correctly detected.
-- SIZE is probed on a single raw TCP connection for all entries at once.

local ok_ftpapi, FtpApi = pcall(require, "apps/cloudstorage/ftpapi")
if ok_ftpapi and FtpApi then
    local DocumentRegistry = require("document/documentregistry")

    function FtpApi:listFolder(address_path, folder_path)
        local ltn12 = require("ltn12")

        -- Parse host/port/credentials from address_path
        local url_module = require("socket.url")
        local parsed  = url_module.parse(address_path)
        local host    = parsed.host
        local port    = parsed.port and tonumber(parsed.port) or nil
        local path    = parsed.path or "/"

        -- Credentials are percent-encoded in the URL — decode them
        local function urldecode(s)
            if not s then return nil end
            return s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
        end
        local user = urldecode(parsed.user)
        local pass = urldecode(parsed.password)


        -- Step 1: NLST to get bare names
        local socket_ftp = require("socket.ftp")
        local t = {}
        local p = baseParams(host, port, user, pass)
        p.path    = path:match("/$") and path or (path .. "/")
        p.command = "nlst"
        p.sink    = ltn12.sink.table(t)
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

        -- Step 2: SIZE probe all names on one connection
        local size_results, probe_err = ftpSizeProbe(host, port, user, pass,
                                                      path, names)
        if not size_results then
            logger.warn("[ftp-folder-dl] browser SIZE probe failed:", probe_err,
                        "— falling back to extension heuristic")
            size_results = {}
            for _, name in ipairs(names) do
                size_results[name] = name:match("%.%w+$") ~= nil
            end
        end

        if folder_path == "/" then folder_path = "" end

        local folders, files = {}, {}
        for _, name in ipairs(names) do
            if size_results[name] then
                -- file
                if DocumentRegistry:hasProvider(name)
                        or G_reader_settings:isTrue("show_unsupported") then
                    table.insert(files, {
                        text = name,
                        url  = folder_path .. "/" .. name,
                        type = "file",
                    })
                end
            else
                -- directory
                table.insert(folders, {
                    text = "▶ " .. name,
                    url  = folder_path .. "/" .. name,
                    type = "folder",
                })
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
                {
                    text = "FTP browser: natural sort (1, 2, 10)",
                    checked_func = function() return get("natural_sort") end,
                    callback = function() set("natural_sort", not get("natural_sort")) end,
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
