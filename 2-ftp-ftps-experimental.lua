--[[
    FTPS (FTP over TLS) support for FTP Download Manager
    =====================================================
    Adds FTPS capability to the base FTP Download Manager patch.

    Requires:  <koreader>/patches/2-ftp-download-manager.lua
    Install as: <koreader>/patches/2-ftp-ftps.lua

    The "2-ftp-" prefix guarantees this file loads AFTER the base patch
    (alphabetically: "2-ftp-download-manager" < "2-ftp-ftps").

    Usage:
      Enter the server IP/hostname in the FTP address field (no scheme prefix).
      Enable FTPS via:  Settings → AI Slop Settings → FTP Download Manager
                        → Use FTPS (TLS encryption)
--]]

local logger = require("logger")

-- ── Dependency check ──────────────────────────────────────────────────────────

local transport = package.loaded["ftp-folder-dl.transport"]
if not transport then
    logger.warn("[ftps] base patch not loaded — aborting")
    return
end

-- ── Settings (shared key space with base patch) ───────────────────────────────

local function get(key)
    local cfg = G_reader_settings:readSetting("ftp_folder_dl") or {}
    if cfg[key] ~= nil then return cfg[key] end
    if key == "use_ftps" then return false end
    return nil
end
local function set(key, value)
    local cfg = G_reader_settings:readSetting("ftp_folder_dl") or {}
    cfg[key] = value
    G_reader_settings:saveSetting("ftp_folder_dl", cfg)
end

-- ── Add FTPS toggle to FTP Download Manager submenu ──────────────────────────
-- The base patch exposes its submenu table via package.loaded before the
-- FileManager is opened, so we can insert directly — no hook chaining needed.

local submenu = package.loaded["ftp-folder-dl.submenu"]
if submenu then
    -- Insert after the enabled toggle (index 1) so it appears near the top.
    local already = false
    for _, item in ipairs(submenu) do
        if item._ftps_entry then already = true; break end
    end
    if not already then
        table.insert(submenu, 2, {
            _ftps_entry  = true,
            text         = "Use FTPS (TLS encryption)",
            checked_func = function() return get("use_ftps") end,
            callback     = function() set("use_ftps", not get("use_ftps")) end,
        })
    end
else
    logger.warn("[ftps] base patch submenu not found — setting entry skipped")
end

-- ── Pure-FFI OpenSSL helpers ──────────────────────────────────────────────────
-- KOReader's bundled LuaSec does not expose SSL* or getsession(), so we bypass
-- it and call OpenSSL directly via LuaJIT FFI for both control and data channels.
-- Using one shared SSL_CTX allows SSL_get1_session(ctrl) + SSL_set_session(data)
-- which satisfies FileZilla Server's mandatory TLS session resumption on PROT P.

local _ftps_ffi_cache = nil  -- nil=not tried, false=unavailable, table=loaded

local function getFtpsFfi()
    if _ftps_ffi_cache ~= nil then
        if _ftps_ffi_cache == false then return nil, nil end
        return _ftps_ffi_cache.ffi, _ftps_ffi_cache.lib
    end
    local ok, ffi = pcall(require, "ffi")
    if not ok then _ftps_ffi_cache = false; return nil, nil end

    local decls = {
        "typedef struct ssl_method_st SSL_METHOD;",
        "typedef struct ssl_ctx_st   SSL_CTX;",
        "typedef struct ssl_st       SSL;",
        "typedef struct ssl_session_st SSL_SESSION;",
        "const SSL_METHOD* TLS_client_method(void);",
        "SSL_CTX* SSL_CTX_new(const SSL_METHOD* meth);",
        "void     SSL_CTX_free(SSL_CTX* ctx);",
        "void     SSL_CTX_set_verify(SSL_CTX* ctx, int mode, void* cb);",
        "long     SSL_CTX_ctrl(SSL_CTX* ctx, int cmd, long larg, void* parg);",
        "SSL*     SSL_new(SSL_CTX* ctx);",
        "void     SSL_free(SSL* ssl);",
        "int      SSL_set_fd(SSL* ssl, int fd);",
        "int      SSL_connect(SSL* ssl);",
        "int      SSL_shutdown(SSL* ssl);",
        "int      SSL_read(SSL* ssl, void* buf, int num);",
        "int      SSL_write(SSL* ssl, const void* buf, int num);",
        "int      SSL_get_error(const SSL* ssl, int ret_code);",
        "SSL_SESSION* SSL_get1_session(SSL* ssl);",
        "int      SSL_set_session(SSL* ssl, SSL_SESSION* session);",
        "void     SSL_SESSION_free(SSL_SESSION* ses);",
        "int      fcntl(int fd, int cmd, ...);",
    }
    for _, d in ipairs(decls) do pcall(ffi.cdef, d) end

    local lib = nil
    for _, name in ipairs({"default", "ssl", "libssl.so.3", "libssl.so.1.1", "libssl.so"}) do
        local candidate
        if name == "default" then
            if pcall(function() ffi.C.TLS_client_method() end) then
                candidate = ffi.C
            end
        else
            local lok, l = pcall(ffi.load, name)
            if lok and pcall(function() l.TLS_client_method() end) then
                candidate = l
            end
        end
        if candidate then lib = candidate; break end
    end

    if lib then
        _ftps_ffi_cache = {ffi=ffi, lib=lib}
        return ffi, lib
    end
    _ftps_ffi_cache = false
    return nil, nil
end

local function newFtpsCtx(lib)
    local ctx = lib.SSL_CTX_new(lib.TLS_client_method())
    if ctx == nil then return nil end
    lib.SSL_CTX_set_verify(ctx, 0, nil)          -- SSL_VERIFY_NONE
    lib.SSL_CTX_ctrl(ctx, 119, 0x0303, nil)      -- SSL_CTRL_SET_MAX_PROTO_VERSION, TLS 1.2
    return ctx
end

-- Set fd to blocking mode. LuaSocket uses non-blocking; OpenSSL needs blocking.
local function setFdBlocking(ffi, fd)
    local ok, flags = pcall(function() return ffi.C.fcntl(fd, 3) end) -- F_GETFL=3
    if ok and flags >= 0 then
        pcall(function() ffi.C.fcntl(fd, 4, bit.band(flags, bit.bnot(0x800))) end) -- F_SETFL, ~O_NONBLOCK
    end
end

-- ── ftpsGet ───────────────────────────────────────────────────────────────────
-- Drop-in replacement for socket.ftp.get. Accepts same `p` table.

local function ftpsGet(p)
    local socket = require("socket")
    local ffi, lib = getFtpsFfi()
    if not ffi or not lib then
        return nil, "FTPS: libssl not available via FFI"
    end

    local host     = p.host
    local port     = p.port or 21
    local user     = p.user
    local pass     = p.password
    local path     = p.path or "/"
    local cmd_name = p.command
    local sink     = p.sink
    local implicit = (port == 990)

    local ctx = newFtpsCtx(lib)
    if not ctx then return nil, "FTPS: SSL_CTX_new failed" end

    local function cleanup(cs, ct, ds, dt)
        if ds then pcall(function() lib.SSL_shutdown(ds) end); lib.SSL_free(ds) end
        if dt then dt:close() end
        if cs then pcall(function() lib.SSL_shutdown(cs) end); lib.SSL_free(cs) end
        if ct then ct:close() end
        lib.SSL_CTX_free(ctx)
    end

    local ctrl_ssl
    local cbuf = ffi.new("char[1]")
    local function ssl_readline()
        local t = {}
        while true do
            local n = lib.SSL_read(ctrl_ssl, cbuf, 1)
            if n <= 0 then return #t > 0 and table.concat(t) or nil end
            local c = ffi.string(cbuf, 1)
            if c == "\n" then return (table.concat(t)):gsub("\r$","") end
            table.insert(t, c)
        end
    end
    local function ftp_recv_ssl()
        local line = ssl_readline()
        if not line then return nil, "connection closed" end
        local code = line:sub(1,3)
        if line:sub(4,4) == "-" then
            repeat
                local cont = ssl_readline()
                if not cont then return nil, "connection closed" end
                line = cont
            until line:sub(1,3) == code and line:sub(4,4) ~= "-"
        end
        return code, line
    end
    local function ftp_cmd_ssl(c)
        local d = c .. "\r\n"
        if lib.SSL_write(ctrl_ssl, d, #d) <= 0 then return nil, "SSL_write failed" end
        return ftp_recv_ssl()
    end

    -- 1. TCP connect
    local tcp = socket.tcp(); tcp:settimeout(30)
    local ok, err = tcp:connect(host, port)
    if not ok then lib.SSL_CTX_free(ctx); return nil, ("FTPS connect %s:%d — %s"):format(host, port, tostring(err)) end
    local ctrl_fd = tcp:getfd()

    -- 2. Explicit FTPS: AUTH TLS over plain TCP
    if not implicit then
        local function plain_recv()
            local line = tcp:receive("*l")
            while line and line:match("^%d%d%d%-") do line = tcp:receive("*l") end
            return line
        end
        if not plain_recv() then tcp:close(); lib.SSL_CTX_free(ctx); return nil, "FTPS: no welcome" end
        tcp:send("AUTH TLS\r\n")
        local auth = tcp:receive("*l")
        if not auth or not auth:match("^234") then
            tcp:close(); lib.SSL_CTX_free(ctx)
            return nil, "FTPS: AUTH TLS rejected: " .. tostring(auth)
        end
    end

    -- 3. Control TLS handshake
    ctrl_ssl = lib.SSL_new(ctx)
    if ctrl_ssl == nil then tcp:close(); lib.SSL_CTX_free(ctx); return nil, "FTPS: SSL_new (ctrl) failed" end
    lib.SSL_set_fd(ctrl_ssl, ctrl_fd)
    setFdBlocking(ffi, ctrl_fd)
    local r = lib.SSL_connect(ctrl_ssl)
    if r ~= 1 then
        local e = lib.SSL_get_error(ctrl_ssl, r)
        cleanup(ctrl_ssl, tcp)
        return nil, ("FTPS: control TLS handshake failed (SSL err %d)"):format(e)
    end
    if implicit then ftp_recv_ssl() end

    -- 4. Authenticate
    local code, line
    if user and user ~= "" then
        code, line = ftp_cmd_ssl("USER " .. user)
        if not code then cleanup(ctrl_ssl, tcp); return nil, "FTPS USER failed" end
        if code == "331" then
            code, line = ftp_cmd_ssl("PASS " .. (pass or ""))
            if not code then cleanup(ctrl_ssl, tcp); return nil, "FTPS PASS failed" end
        end
        if code ~= "230" then
            cleanup(ctrl_ssl, tcp)
            return nil, ("FTPS login failed (%s): %s"):format(code, tostring(line))
        end
    else
        ftp_cmd_ssl("USER anonymous"); ftp_cmd_ssl("PASS guest@")
    end

    -- 5. PBSZ 0 + PROT P
    ftp_cmd_ssl("PBSZ 0"); ftp_cmd_ssl("PROT P")

    -- 6. Binary mode
    ftp_cmd_ssl("TYPE I")

    -- 7. EPSV → PASV
    local data_host, data_port_num
    code, line = ftp_cmd_ssl("EPSV")
    if code == "229" then
        local ep = line:match("%(|[^|]*|[^|]*|(%d+)|%)")
        if ep then data_host = host; data_port_num = tonumber(ep) else code = nil end
    end
    if code ~= "229" then
        code, line = ftp_cmd_ssl("PASV")
        if not code or code ~= "227" then cleanup(ctrl_ssl, tcp); return nil, "FTPS PASV: " .. tostring(line) end
        local h1,h2,h3,h4,p1,p2 = line:match("(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)")
        if not h1 then cleanup(ctrl_ssl, tcp); return nil, "FTPS PASV parse: " .. tostring(line) end
        data_host = h1.."."..h2.."."..h3.."."..h4
        data_port_num = tonumber(p1)*256 + tonumber(p2)
    end

    -- 8. Data TCP connect
    local dtcp = socket.tcp(); dtcp:settimeout(30)
    local dok, derr = dtcp:connect(data_host, data_port_num)
    if not dok then cleanup(ctrl_ssl, tcp); return nil, ("FTPS data connect — %s"):format(tostring(derr)) end
    local data_fd = dtcp:getfd()

    -- 9. Data TLS with session resumption
    local data_ssl = lib.SSL_new(ctx)
    if data_ssl == nil then dtcp:close(); cleanup(ctrl_ssl, tcp); return nil, "FTPS: SSL_new (data) failed" end
    lib.SSL_set_fd(data_ssl, data_fd)
    setFdBlocking(ffi, data_fd)
    local ctrl_sess = lib.SSL_get1_session(ctrl_ssl)
    if ctrl_sess ~= nil then
        lib.SSL_set_session(data_ssl, ctrl_sess)
        lib.SSL_SESSION_free(ctrl_sess)
        logger.dbg("[ftps] data channel: session resumption set")
    else
        logger.warn("[ftps] data channel: SSL_get1_session returned nil")
    end
    local dr = lib.SSL_connect(data_ssl)
    if dr ~= 1 then
        local e = lib.SSL_get_error(data_ssl, dr)
        lib.SSL_shutdown(data_ssl); lib.SSL_free(data_ssl); dtcp:close()
        cleanup(ctrl_ssl, tcp)
        return nil, ("FTPS data TLS handshake failed (SSL err %d)"):format(e)
    end

    -- 10. FTP command
    local fcmd
    if not cmd_name then fcmd = "RETR " .. path
    elseif cmd_name:lower() == "mlsd" then fcmd = "MLSD " .. (path:match("/$") and path or path.."/")
    elseif cmd_name:lower() == "list" then fcmd = "LIST " .. (path:match("/$") and path or path.."/")
    elseif cmd_name:lower() == "nlst" then fcmd = "NLST " .. path
    else fcmd = cmd_name:upper() .. " " .. path end

    code, line = ftp_cmd_ssl(fcmd)
    if not code or (code ~= "125" and code ~= "150") then
        lib.SSL_shutdown(data_ssl); lib.SSL_free(data_ssl); dtcp:close(); cleanup(ctrl_ssl, tcp)
        return nil, ("FTPS %s failed (%s): %s"):format(fcmd, tostring(code), tostring(line))
    end

    -- 11. Stream data through ltn12 sink
    local rbuf = ffi.new("char[?]", 8192)
    while true do
        local n = lib.SSL_read(data_ssl, rbuf, 8192)
        if n <= 0 then break end
        local sres, serr = sink(ffi.string(rbuf, n))
        if not sres then
            lib.SSL_shutdown(data_ssl); lib.SSL_free(data_ssl); dtcp:close(); cleanup(ctrl_ssl, tcp)
            return nil, "FTPS sink: " .. tostring(serr)
        end
    end
    sink(nil)

    -- 12. Cleanup
    lib.SSL_shutdown(data_ssl); lib.SSL_free(data_ssl); dtcp:close()
    ftp_recv_ssl()
    ftp_cmd_ssl("QUIT")
    lib.SSL_shutdown(ctrl_ssl); lib.SSL_free(ctrl_ssl); tcp:close()
    lib.SSL_CTX_free(ctx)
    return 1
end

-- ── Install transport override ────────────────────────────────────────────────

transport.get = function(p)
    if get("use_ftps") then return ftpsGet(p) end
    return require("socket.ftp").get(p)
end

-- ── URL parser ───────────────────────────────────────────────────────────────
-- KOReader's generateUrl prepends "ftp://" to self.address, producing
-- "ftp://ftps://host" (double-scheme) via our openCloudServer masquerade.
-- This parser peels all leading schemes to recover host/port/user/pass/path.

local function parseUrlForFtps(url)
    local work = url
    while true do
        local scheme = work:match("^(ftps?)://")
        if scheme then work = work:sub(#scheme + 4) else break end
    end
    local userinfo, rest = work:match("^([^@]+)@(.+)$")
    if not userinfo then rest = work end
    local raw_user, raw_pass
    if userinfo then raw_user, raw_pass = userinfo:match("^([^:]*):?(.*)$") end
    while rest:match("^ftps?://") do
        local s = rest:match("^(ftps?)://")
        rest = rest:sub(#s + 4)
    end
    local host, port_str, path
    host, port_str, path = rest:match("^([^:/]+):(%d+)(/.*)$")
    if not host then host, path = rest:match("^([^:/]+)(/.*)$") end
    if not host then host = rest:match("^([^:/]+)") or rest end
    path = (path and path ~= "") and path or "/"
    local ud = function(s)
        if not s or s == "" then return nil end
        return s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h,16)) end)
    end
    return host, port_str and tonumber(port_str) or nil, ud(raw_user), ud(raw_pass), path
end

-- ── CloudStorage:openCloudServer patch ───────────────────────────────────────
-- When FTPS is on, embed "ftps://" in self.address before delegating to
-- KOReader's dispatcher so generateUrl produces the double-scheme URL that
-- our listFolder parser unwraps to host + use_tls=true.

local ok_cs, CloudStorage = pcall(require, "apps/cloudstorage/cloudstorage")
if ok_cs and CloudStorage then
    local orig_open = CloudStorage.openCloudServer
    function CloudStorage:openCloudServer(url)
        if self.type == "ftp" and get("use_ftps") then
            local orig_addr = self.address or ""
            self.address = "ftps://" .. orig_addr:gsub("^ftps?://", "")
            local ok, err = pcall(orig_open, self, url)
            self.address = orig_addr
            if not ok then logger.warn("[ftps] openCloudServer error:", err) end
            return
        end
        return orig_open(self, url)
    end
else
    logger.warn("[ftps] CloudStorage not found")
end

-- ── FtpApi:listFolder patch ───────────────────────────────────────────────────

local ok_fa, FtpApi = pcall(require, "apps/cloudstorage/ftpapi")
if ok_fa and FtpApi then
    local DocumentRegistry = require("document/documentregistry")
    local _mlsd_ok = {}

    local function fmtSz(bytes)
        if not bytes then return "" end
        local nb = "\194\160"
        if bytes < 1024 then return (" %d"..nb.."B"):format(bytes) end
        if bytes < 1048576 then return (" %.1f"..nb.."KB"):format(bytes/1024) end
        if bytes < 1073741824 then return (" %.1f"..nb.."MB"):format(bytes/1048576) end
        return (" %.1f"..nb.."GB"):format(bytes/1073741824)
    end

    local function nlSort(a, b)
        a, b = a:lower(), b:lower()
        local ffiUtil = require("ffi/util")
        local ia, ib = 1, 1
        while ia <= #a and ib <= #b do
            local da, db = a:sub(ia):match("^%d+"), b:sub(ib):match("^%d+")
            if da and db then
                local na, nb = tonumber(da), tonumber(db)
                if na ~= nb then return na < nb end
                ia = ia + #da; ib = ib + #db
            else
                local ca, cb = a:sub(ia,ia), b:sub(ib,ib)
                if ca ~= cb then return ffiUtil.strcoll(ca,cb) end
                ia = ia+1; ib = ib+1
            end
        end
        return #a < #b
    end

    local function buildResult(entries, folder_path)
        if folder_path == "/" then folder_path = "" end
        local folders, files = {}, {}
        local cfg = G_reader_settings:readSetting("ftp_folder_dl") or {}
        local ns = cfg.natural_sort ~= false
        for _, e in ipairs(entries) do
            if e.is_dir then
                table.insert(folders, {text="▶ "..e.name, url=folder_path.."/"..e.name, type="folder"})
            elseif DocumentRegistry:hasProvider(e.name) or G_reader_settings:isTrue("show_unsupported") then
                table.insert(files, {
                    text=e.name, url=folder_path.."/"..e.name, type="file",
                    mandatory=e.size and fmtSz(e.size):gsub("^ ","") or nil,
                })
            end
        end
        if ns then
            local sf = function(a,b) return nlSort(a.text,b.text) end
            table.sort(folders,sf); table.sort(files,sf)
        end
        local r = {}
        for _,v in ipairs(folders) do table.insert(r,v) end
        for _,v in ipairs(files)   do table.insert(r,v) end
        return r
    end

    local function parseMlsdInline(raw)
        local entries = {}
        for line in (raw or ""):gmatch("[^\r\n]+") do
            local facts, name = line:match("^([^%s]+)%s+(.+)$")
            if facts and name then
                name = name:match("^%s*(.-)%s*$")
                if name ~= "" and name ~= "." and name ~= ".." then
                    local tv = (facts:match("[Tt]ype=([^;]+)") or ""):lower()
                    if tv == "dir" or tv == "cdir" then
                        table.insert(entries, {name=name, is_dir=true})
                    elseif tv == "file" or tv == "os.unix=symlink" then
                        table.insert(entries, {name=name, is_dir=false, size=tonumber(facts:match("[Ss]ize=(%d+)"))})
                    end
                end
            end
        end
        return entries
    end

    local function parseListInline(raw)
        local entries = {}
        local months = {jan=1,feb=2,mar=3,apr=4,may=5,jun=6,jul=7,aug=8,sep=9,oct=10,nov=11,dec=12}
        for line in (raw or ""):gmatch("[^\r\n]+") do
            local first = line:sub(1,1)
            if first=="d" or first=="-" or first=="l" then
                local tokens = {}
                for tok in line:gmatch("%S+") do table.insert(tokens, tok) end
                local mi
                for i=3,math.min(8,#tokens) do
                    if months[tokens[i]:lower()] then mi=i; break end
                end
                if mi and mi+3 <= #tokens then
                    local name = table.concat(tokens," ",mi+3)
                    if first=="l" then name = name:match("^(.-)%s+%->") or name end
                    name = name:match("^%s*(.-)%s*$")
                    if name ~= "" and name ~= "." and name ~= ".." then
                        local is_dir = (first=="d" or first=="l")
                        table.insert(entries, {name=name, is_dir=is_dir, size=not is_dir and tonumber(tokens[mi-1]) or nil})
                    end
                end
            end
        end
        return entries
    end

    local _orig_listFolder = FtpApi.listFolder
    function FtpApi:listFolder(address_path, folder_path)
        if not get("use_ftps") then
            return _orig_listFolder(self, address_path, folder_path)
        end

        local host, port, user, pass, path = parseUrlForFtps(address_path)
        logger.dbg("[ftps] listFolder:", host, path)
        local ltn12 = require("ltn12")

        local function make_p(cmd, t)
            local p = {host=host, type="i", path=path:match("/$") and path or path.."/", command=cmd, sink=ltn12.sink.table(t)}
            if port then p.port=port end
            if user then p.user=user; p.password=pass or "" end
            return p
        end

        -- MLSD
        local host_key = host..":"..tostring(port)
        if _mlsd_ok[host_key] ~= false then
            local t = {}
            logger.info("[ftps] MLSD", host, path)
            local ok, err = ftpsGet(make_p("mlsd", t))
            if ok then
                _mlsd_ok[host_key] = true
                local entries = parseMlsdInline(table.concat(t))
                return buildResult(entries, folder_path)
            else
                logger.info("[ftps] browser MLSD failed, trying LIST:", err)
                _mlsd_ok[host_key] = false
            end
        end

        -- LIST
        local t = {}
        logger.info("[ftps] LIST", host, path)
        local ok, err = ftpsGet(make_p("list", t))
        if ok then
            local entries = parseListInline(table.concat(t))
            if #entries > 0 then return buildResult(entries, folder_path) end
        end

        logger.warn("[ftps] browser MLSD+LIST failed:", err)
        return {}
    end
else
    logger.warn("[ftps] FtpApi not found, listFolder patch skipped")
end

-- ── Ftp:downloadFile patch ────────────────────────────────────────────────────
-- Stock Ftp:downloadFile calls socket.ftp.get directly (not through transport).
-- Intercept it when FTPS is on and route to ftpsGet.

local ok_ftp, Ftp_mod = pcall(require, "apps/cloudstorage/ftp")
if ok_ftp and Ftp_mod then
    local _orig_dl = Ftp_mod.downloadFile
    function Ftp_mod:downloadFile(item, address, username, password, path_dir, callback_close, progress_cb)
        if not get("use_ftps") then
            return _orig_dl(self, item, address, username, password, path_dir, callback_close, progress_cb)
        end
        -- Strip all scheme prefixes to get bare host
        local bare = (address or ""):gsub("^ftps?://",""):gsub("^ftps?://","")
        local host, port_str = bare:match("^([^:/]+):(%d+)")
        if not host then host = bare:match("^([^:/]+)") or bare end
        local port = port_str and tonumber(port_str) or nil
        local ud = function(s)
            if not s or s == "" then return nil end
            return s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h,16)) end)
        end
        logger.info("[ftps] downloadFile:", host, item.url)
        local UIManager   = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        local ltn12       = require("ltn12")
        local msg = InfoMessage:new{ text = "Downloading " .. item.text .. "…" }
        UIManager:show(msg); UIManager:forceRePaint()
        local f, ferr = io.open(path_dir, "wb")
        if not f then
            UIManager:close(msg)
            UIManager:show(InfoMessage:new{ text = "Cannot write file: "..tostring(ferr), timeout=5 })
            return
        end
        local p = { host=host, port=port, user=ud(username), password=ud(password),
                    path=item.url, sink=ltn12.sink.file(f), type="i" }
        local ok_dl, dl_err = ftpsGet(p)
        UIManager:close(msg)
        if not ok_dl then
            pcall(function() os.remove(path_dir) end)
            UIManager:show(InfoMessage:new{ text = "Download failed: "..tostring(dl_err), timeout=5 })
        else
            UIManager:show(InfoMessage:new{ text = "Saved to "..path_dir, timeout=3 })
        end
        if callback_close then callback_close() end
    end
else
    logger.warn("[ftps] Ftp module not found, single-file download patch skipped")
end

logger.info("[ftps] patch applied")
