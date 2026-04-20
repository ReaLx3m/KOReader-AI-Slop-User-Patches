--[[
    FTP Download Manager — fully standalone plugin
    ================================================
    Manages its own list of FTP servers. No dependency on CloudStorage.

    Entry point:  Settings → FTP Download Manager → Browse servers

    Features:
      - Own server list stored in plugin settings
      - MLSD directory listing (RFC 3659) with fallback to LIST, then NLST+SIZE
      - File downloads pipe directly to disk (no memory buffering)
      - Opportunistic TLS (AUTH TLS) on connect
      - Connection pooling across browse/download operations
      - Natural sort, conflict handling, folder structure options

    Install as:  <koreader>/plugins/ftpdownloadmanager.koplugin/
--]]

local WidgetContainer    = require("ui/widget/container/widgetcontainer")
local Dispatcher         = require("dispatcher")
local logger             = require("logger")
local FileManagerMenu    = require("apps/filemanager/filemanagermenu")
local FileManagerMenuOrder = require("ui/elements/filemanager_menu_order")

logger.info("[ftp-dl] loading plugin...")

local FTPDownloadManager = WidgetContainer:extend{
    name          = "ftpdownloadmanager",
    is_doc_plugin = false,
}

-- ── Settings ──────────────────────────────────────────────────────────────────

local DEFAULTS = {
    enabled          = true,
    on_conflict      = "skip",
    natural_sort     = true,
    items_per_page   = 10,
    selection_shrink = false,
    keep_structure   = false,
    prefer_ftps      = false,
    bigger_buttons   = 100,       -- percentage; 100=normal, 50-200
    bigger_buttons_width = 100,  -- percentage; 100=normal, 50-200
    item_height      = 4,          -- item row padding (scaleBySize); 1-10
    item_font_size   = 20,         -- font size for file/folder name buttons
    index_refresh_days = 7,        -- 0=never auto-refresh, 1-90 days
    index_always_reindex = false,  -- remembered state of "Re-index contents" checkbox

}

-- Plugin settings and server list are stored in their own dedicated file,
-- completely separate from G_reader_settings (settings.reader.lua).
local _LuaSettings  = require("luasettings")
local _DataStorage  = require("datastorage")
local _plugin_settings = _LuaSettings:open(
    _DataStorage:getSettingsDir() .. "/ftpdownloadmanager.lua")

local function get(key)
    local v = _plugin_settings:readSetting(key)
    if v ~= nil then return v end
    return DEFAULTS[key]
end
local function set(key, value)
    _plugin_settings:saveSetting(key, value)
    _plugin_settings:flush()
end

-- ── Server list persistence ───────────────────────────────────────────────────
-- Each server: { name, address, username, password }

local function getServers()
    return _plugin_settings:readSetting("servers") or {}
end

local function saveServers(servers)
    _plugin_settings:saveSetting("servers", servers)
    _plugin_settings:flush()
end

-- ── Natural sort ──────────────────────────────────────────────────────────────

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
            ia = ia + #da; ib = ib + #db
        else
            local ca, cb = a:sub(ia, ia), b:sub(ib, ib)
            if ca ~= cb then return ffiUtil.strcoll(ca, cb) end
            ia = ia + 1; ib = ib + 1
        end
    end
    return #a < #b
end

-- ── FTP helpers ───────────────────────────────────────────────────────────────

local function parseAddress(address)
    local bare = (address or ""):gsub("^ftps?://", "")
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

-- ── Opportunistic TLS ─────────────────────────────────────────────────────────

local _ffi_cache = nil

local function getTlsFfi()
    if _ffi_cache ~= nil then
        if _ffi_cache == false then return nil, nil end
        return _ffi_cache.ffi, _ffi_cache.lib
    end
    local ok, ffi = pcall(require, "ffi")
    if not ok then _ffi_cache = false; return nil, nil end
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
    for _, name in ipairs({"default","ssl","libssl.so.3","libssl.so.1.1","libssl.so"}) do
        local candidate
        if name == "default" then
            if pcall(function() ffi.C.TLS_client_method() end) then candidate = ffi.C end
        else
            local lok, l = pcall(ffi.load, name)
            if lok and pcall(function() l.TLS_client_method() end) then candidate = l end
        end
        if candidate then lib = candidate; break end
    end
    if lib then _ffi_cache = {ffi=ffi, lib=lib}; return ffi, lib end
    _ffi_cache = false; return nil, nil
end

local function newTlsCtx(lib)
    local ctx = lib.SSL_CTX_new(lib.TLS_client_method())
    if ctx == nil then return nil end
    lib.SSL_CTX_set_verify(ctx, 0, nil)
    lib.SSL_CTX_ctrl(ctx, 119, 0x0303, nil)
    return ctx
end

local function setFdBlocking(ffi, fd)
    local ok, flags = pcall(function() return ffi.C.fcntl(fd, 3) end)
    if ok and flags >= 0 then
        pcall(function() ffi.C.fcntl(fd, 4, bit.band(flags, bit.bnot(0x800))) end)
    end
end

-- ── Connection pool ───────────────────────────────────────────────────────────

local _conn_pool = {}

local function connKey(host, port, user)
    return host .. ":" .. tostring(port) .. ":" .. tostring(user or "")
end

local function closePool()
    for key, conn in pairs(_conn_pool) do
        pcall(function()
            -- Short timeout so a dead socket doesn't hang for 30s
            if conn.tcp then conn.tcp:settimeout(5) end
            conn:close()
        end)
        _conn_pool[key] = nil
    end
    -- Reset MLSD cache so fresh connections re-probe on next use
    _mlsd_supported = {}
end

local function autoConnect(host, port, user, pass)
    local socket = require("socket")
    port = port or 21

    local function tcp_connect()
        local t = socket.tcp(); t:settimeout(30)
        local ok, err = t:connect(host, port)
        if not ok then return nil, err end
        return t
    end
    local function tcp_recv_lines(t)
        local lines, code = {}, nil
        while true do
            local line = t:receive("*l")
            if not line then return nil, "connection closed" end
            table.insert(lines, line)
            if not code then code = line:sub(1,3) end
            if line:sub(1,3) == code and line:sub(4,4) ~= "-" then break end
        end
        return code, table.concat(lines, "\n")
    end
    local function tcp_cmd(t, c) t:send(c.."\r\n"); return tcp_recv_lines(t) end

    local tcp, conn_err
    local function plainConnect()
        local pt, pe = tcp_connect()
        if not pt then
            return nil, ("FTP connect %s:%d - %s"):format(host, port, tostring(pe))
        end
        tcp_recv_lines(pt)
        local pcode
        if user and user ~= "" then
            pcode = tcp_cmd(pt, "USER "..user)
            if pcode == "331" then pcode = tcp_cmd(pt, "PASS "..(pass or "")) end
        else
            tcp_cmd(pt, "USER anonymous"); pcode = tcp_cmd(pt, "PASS guest@")
        end
        if pcode ~= "230" then pt:close(); return nil, ("FTP login failed (%s)"):format(tostring(pcode)) end
        local c = { host=host, port=port, alive=true, tls=false, tcp=pt }
        function c:recv()  return tcp_recv_lines(pt) end
        function c:cmd(s)  pt:send(s.."\r\n"); return self:recv() end
        function c:close()
            if not self.alive then return end
            self.alive = false
            pcall(function() self:cmd("QUIT") end)
            pcall(function() self.tcp:close() end)
        end
        c:cmd("TYPE I")
        return c
    end

    if get("prefer_ftps") then goto try_ftps end
    do local c = plainConnect(); if c then return c end end

    ::try_ftps::
    local ffi, lib = getTlsFfi()
    if not ffi or not lib then return nil, "FTP login failed and libssl unavailable for FTPS" end

    tcp, conn_err = tcp_connect()
    if not tcp then return nil, ("FTPS reconnect %s:%d - %s"):format(host, port, tostring(conn_err)) end
    tcp_recv_lines(tcp)

    local auth_code = tcp_cmd(tcp, "AUTH TLS")
    if auth_code ~= "234" then tcp:close(); return plainConnect() end

    local ctx = newTlsCtx(lib)
    if not ctx then tcp:close(); return nil, "FTPS: SSL_CTX_new failed" end

    local ctrl_ssl = lib.SSL_new(ctx)
    local ctrl_fd  = tcp:getfd()
    lib.SSL_set_fd(ctrl_ssl, ctrl_fd)
    setFdBlocking(ffi, ctrl_fd)
    local r = lib.SSL_connect(ctrl_ssl)
    if r ~= 1 then
        lib.SSL_free(ctrl_ssl); lib.SSL_CTX_free(ctx); tcp:close()
        return plainConnect()
    end

    local conn = { host=host, port=port, alive=true, tls=true,
                   ffi=ffi, lib=lib, ctx=ctx, tcp=tcp, ctrl_ssl=ctrl_ssl,
                   cbuf=ffi.new("char[1]") }
    function conn:ssl_readline()
        local t = {}
        while true do
            local n = self.lib.SSL_read(self.ctrl_ssl, self.cbuf, 1)
            if n <= 0 then return nil end
            local c = self.ffi.string(self.cbuf, 1)
            if c == "\n" then return (table.concat(t)):gsub("\r$","") end
            table.insert(t, c)
        end
    end
    function conn:recv()
        local lines, code = {}, nil
        while true do
            local line = self:ssl_readline()
            if not line then return nil, "connection closed" end
            table.insert(lines, line)
            if not code then code = line:sub(1,3) end
            if line:sub(1,3) == code and line:sub(4,4) ~= "-" then break end
        end
        return code, table.concat(lines, "\n")
    end
    function conn:cmd(c)
        local d = c.."\r\n"
        if self.lib.SSL_write(self.ctrl_ssl, d, #d) <= 0 then return nil, "SSL_write failed" end
        return self:recv()
    end
    function conn:close()
        if not self.alive then return end
        self.alive = false
        pcall(function() self:cmd("QUIT") end)
        pcall(function() self.lib.SSL_shutdown(self.ctrl_ssl) end)
        self.lib.SSL_free(self.ctrl_ssl)
        pcall(function() self.tcp:close() end)
        self.lib.SSL_CTX_free(self.ctx)
    end
    conn:cmd("PBSZ 0"); conn:cmd("PROT P")

    local code, line
    if user and user ~= "" then
        code, line = conn:cmd("USER "..user)
        if not code then conn:close(); return nil, "FTPS USER failed" end
        if code == "331" then
            code, line = conn:cmd("PASS "..(pass or ""))
            if not code then conn:close(); return nil, "FTPS PASS failed" end
        end
        if code ~= "230" then
            conn:close()
            return nil, ("FTPS login failed (%s): %s"):format(code, tostring(line))
        end
    else
        conn:cmd("USER anonymous"); conn:cmd("PASS guest@")
    end
    conn:cmd("TYPE I")
    return conn
end

local function getConn(host, port, user, pass)
    local key  = connKey(host, port, user)
    local conn = _conn_pool[key]
    if conn and conn.alive then
        local noop_code = conn:cmd("NOOP")
        if noop_code ~= "200" then conn.alive = false; conn = nil end
    end
    if not conn or not conn.alive then
        local err
        conn, err = autoConnect(host, port, user, pass)
        if not conn then return nil, err end
        _conn_pool[key] = conn
    end
    return conn
end

-- ── Data channel transfer ─────────────────────────────────────────────────────

local function doTransfer(conn, host, cmd_name, path, sink)
    local socket = require("socket")
    local data_host, data_port_num
    local code, line = conn:cmd("EPSV")
    if code == "229" then
        local ep = line:match("%(|[^|]*|[^|]*|(%d+)|%)")
        if ep then data_host = host; data_port_num = tonumber(ep) else code = nil end
    end
    if code ~= "229" then
        code, line = conn:cmd("PASV")
        if not code or code ~= "227" then return nil, "ctrl", "FTP PASV: "..tostring(line) end
        local h1,h2,h3,h4,p1,p2 = line:match("(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)")
        if not h1 then return nil, "ctrl", "FTP PASV parse: "..tostring(line) end
        data_host     = h1.."."..h2.."."..h3.."."..h4
        data_port_num = tonumber(p1)*256 + tonumber(p2)
    end

    local dtcp = socket.tcp(); dtcp:settimeout(30)
    local dok, derr = dtcp:connect(data_host, data_port_num)
    if not dok then return nil, "data", ("FTP data connect — %s"):format(tostring(derr)) end

    local read_data, close_data
    if conn.tls then
        local ffi, lib = conn.ffi, conn.lib
        local data_fd  = dtcp:getfd()
        local data_ssl = lib.SSL_new(conn.ctx)
        if data_ssl == nil then dtcp:close(); return nil, "data", "FTP: SSL_new (data) failed" end
        lib.SSL_set_fd(data_ssl, data_fd)
        setFdBlocking(ffi, data_fd)
        local ctrl_sess = lib.SSL_get1_session(conn.ctrl_ssl)
        if ctrl_sess ~= nil then lib.SSL_set_session(data_ssl, ctrl_sess); lib.SSL_SESSION_free(ctrl_sess) end
        local dr = lib.SSL_connect(data_ssl)
        if dr ~= 1 then
            local e = lib.SSL_get_error(data_ssl, dr)
            lib.SSL_shutdown(data_ssl); lib.SSL_free(data_ssl); dtcp:close()
            return nil, "data", ("FTP data TLS handshake failed (SSL err %d)"):format(e)
        end
        local rbuf = ffi.new("char[?]", 8192)
        read_data  = function()
            local n = lib.SSL_read(data_ssl, rbuf, 8192)
            if n <= 0 then return nil end
            return ffi.string(rbuf, n)
        end
        close_data = function() lib.SSL_shutdown(data_ssl); lib.SSL_free(data_ssl); dtcp:close() end
    else
        read_data  = function()
            local chunk, e, partial = dtcp:receive(8192)
            if chunk then return chunk end
            if partial and partial ~= "" then return partial end
            return nil
        end
        close_data = function() dtcp:close() end
    end

    local fcmd
    if     not cmd_name                      then fcmd = "RETR "..path
    elseif cmd_name:lower() == "mlsd"        then fcmd = "MLSD "..(path:match("/$") and path or path.."/")
    elseif cmd_name:lower() == "list"        then fcmd = "LIST "..(path:match("/$") and path or path.."/")
    elseif cmd_name:lower() == "nlst"        then fcmd = "NLST "..path
    else                                          fcmd = cmd_name:upper().." "..path end

    code, line = conn:cmd(fcmd)
    if not code or (code ~= "125" and code ~= "150") then
        close_data()
        return nil, "ctrl", ("FTP %s failed (%s): %s"):format(fcmd, tostring(code), tostring(line))
    end
    while true do
        local chunk = read_data()
        if not chunk then break end
        local sres, serr = sink(chunk)
        if not sres then close_data(); sink(nil); return nil, "data", "FTP sink: "..tostring(serr) end
    end
    sink(nil); close_data(); conn:recv()
    return 1
end

local function connDoGet(p)
    local conn, cerr = getConn(p.host, p.port or 21, p.user, p.password)
    if not conn then return nil, cerr end
    local ok, r, chan, errmsg = pcall(doTransfer, conn, p.host, p.command, p.path or "/", p.sink)
    if not ok then
        conn.alive = false; _conn_pool[connKey(p.host, p.port or 21, p.user)] = nil
        return nil, tostring(r)
    end
    if not r then
        if chan == "ctrl" then conn.alive = false; _conn_pool[connKey(p.host, p.port or 21, p.user)] = nil end
        return nil, errmsg
    end
    return 1
end

-- ── MLSD listing ─────────────────────────────────────────────────────────────

local function parseMlsd(raw)
    local entries = {}
    for line in (raw or ""):gmatch("[^\r\n]+") do
        local facts, name = line:match("^([^%s]+)%s+(.+)$")
        if facts and name then
            name = name:match("^%s*(.-)%s*$")
            if name ~= "" and name ~= "." and name ~= ".." then
                local type_val = (facts:match("[Tt]ype=([^;]+)") or ""):lower()
                if type_val == "dir" or type_val == "cdir" or type_val == "pdir" then
                    table.insert(entries, { name=name, is_dir=true })
                elseif type_val == "file" or type_val == "os.unix=symlink" then
                    table.insert(entries, { name=name, is_dir=false,
                                            size=tonumber(facts:match("[Ss]ize=(%d+)")) })
                end
            end
        end
    end
    return entries
end

local function ftpMlsd(host, port, username, password, path)
    local ltn12 = require("ltn12")
    if not path:match("/$") then path = path.."/" end
    local t = {}
    local p = baseParams(host, port, username, password)
    p.path = path; p.command = "mlsd"; p.sink = ltn12.sink.table(t)
    local ok, err = connDoGet(p)
    if not ok then return nil, err end
    return table.concat(t)
end

-- ── LIST parser (ftpparse port) ──────────────────────────────────────────────

local _months = { jan=0,feb=1,mar=2,apr=3,may=4,jun=5,jul=6,aug=7,sep=8,oct=9,nov=10,dec=11 }

local function ftpParseLine(line)
    if not line or #line < 2 then return nil end
    local first = line:sub(1,1)
    if first == "+" then
        local flagtrycwd, i = false, 2
        while i <= #line do
            local c = line:sub(i,i)
            if c == "\t" then
                local name = line:sub(i+1):match("^%s*(.-)%s*$")
                return name ~= "" and { name=name, is_dir=flagtrycwd } or nil
            elseif c == "/" then flagtrycwd=true; i=i+1
            elseif c == "," then i=i+1
            else while i<=#line and line:sub(i,i)~="," do i=i+1 end
            end
        end
        return nil
    end
    if first=="b" or first=="c" or first=="d" or first=="l" or
       first=="p" or first=="s" or first=="-" then
        local flagtrycwd = (first=="d" or first=="l")
        local tokens = {}
        for tok in line:gmatch("%S+") do table.insert(tokens, tok) end
        if #tokens < 4 then return nil end
        local month_idx
        for i = 3, math.min(8,#tokens) do
            if _months[tokens[i]:lower()] then month_idx=i; break end
        end
        if not month_idx or month_idx+3 > #tokens then return nil end
        local tok_count, in_space, pos, name_start = 0, true, 1, nil
        while pos <= #line do
            local c = line:sub(pos,pos)
            if c==" " or c=="\t" then in_space=true
            else
                if in_space then
                    tok_count=tok_count+1
                    if tok_count==month_idx+3 then name_start=pos; break end
                    in_space=false
                end
            end
            pos=pos+1
        end
        if not name_start then return nil end
        local name = line:sub(name_start):match("^%s*(.-)%s*$")
        if not name or name=="" or name=="." or name==".." then return nil end
        if first=="l" then name = name:match("^(.-)%s+%->%s+.+$") or name end
        if line:sub(2,2)==" " or line:sub(2,2)=="[" then name=name:match("^%s*(.-)%s*$") end
        return { name=name, is_dir=flagtrycwd, size=not flagtrycwd and tonumber(tokens[month_idx-1]) or nil }
    end
    local semi = line:find(";")
    if semi then
        local name = line:sub(1,semi-1)
        local is_dir = #name>4 and name:sub(-4):upper()==".DIR"
        if is_dir then name=name:sub(1,-5) end
        return name~="" and { name=name, is_dir=is_dir } or nil
    end
    if first:match("%d") then
        local dir_name = line:match("^%d+%-%d+%-%d+%s+%d+:%d+%a+%s+<DIR>%s+(.+)$")
        if dir_name then
            dir_name = dir_name:match("^%s*(.-)%s*$")
            return (dir_name~="" and dir_name~="." and dir_name~="..") and { name=dir_name, is_dir=true } or nil
        end
        local size_str, file_name = line:match("^%d+%-%d+%-%d+%s+%d+:%d+%a+%s+(%d+)%s+(.+)$")
        if file_name then
            file_name = file_name:match("^%s*(.-)%s*$")
            return file_name~="" and { name=file_name, is_dir=false, size=tonumber(size_str) } or nil
        end
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
    local ltn12 = require("ltn12")
    if not path:match("/$") then path=path.."/" end
    local t = {}
    local p = baseParams(host, port, username, password)
    p.path=path; p.command="list"; p.sink=ltn12.sink.table(t)
    local ok, err = connDoGet(p)
    if not ok then return nil, err end
    return table.concat(t)
end

local _mlsd_supported = {}

local function ftpListEntriesMlsdList(host, port, username, password, path)
    local host_key = host..":"..tostring(port)
    if _mlsd_supported[host_key] ~= false then
        local raw, err = ftpMlsd(host, port, username, password, path)
        if raw then _mlsd_supported[host_key]=true; return parseMlsd(raw) end
        logger.info("[ftp-dl] MLSD not supported, falling back to LIST:", err)
        _mlsd_supported[host_key] = false
    end
    local raw, err = ftpList(host, port, username, password, path)
    if not raw then return nil, err end
    return parseList(raw)
end

local function ftpSizeProbe(host, port, username, password, path, names)
    local socket = require("socket")
    local tcp    = socket.tcp(); tcp:settimeout(15)
    local ok, err = tcp:connect(host, port or 21)
    if not ok then tcp:close(); return nil, err end
    local function recv()
        local line = tcp:receive("*l")
        if not line then tcp:close(); return nil end
        while line:match("^%d%d%d%-") do line=tcp:receive("*l"); if not line then tcp:close(); return nil end end
        return line
    end
    local function cmd(c) tcp:send(c.."\r\n"); return recv() end
    recv()
    if username and username~="" then cmd("USER "..username); cmd("PASS "..(password or ""))
    else cmd("USER anonymous"); cmd("PASS guest@") end
    cmd("TYPE I")
    local dir_path = path:gsub("/$","")
    local results  = {}
    for _, name in ipairs(names) do
        local r = cmd("SIZE "..dir_path.."/"..name)
        results[name] = r and r:match("^213 ")
            and { is_file=true, size=tonumber(r:match("^213 (%d+)")) }
            or  { is_file=false }
    end
    cmd("QUIT"); tcp:close()
    return results
end

local function ftpListEntriesNlstSize(host, port, username, password, path)
    local ltn12 = require("ltn12")
    if not path:match("/$") then path=path.."/" end
    local t = {}
    local p = baseParams(host, port, username, password)
    p.path=path; p.command="nlst"; p.sink=ltn12.sink.table(t)
    local ok, err = connDoGet(p)
    if not ok then return nil, err end
    local names = {}
    for line in (table.concat(t).."\n"):gmatch("(.-)\r?\n") do
        line = line:match("^%s*(.-)%s*$")
        if line~="" then
            local name = line:match("([^/]+)/?$") or line
            if name~="" then table.insert(names, name) end
        end
    end
    if #names == 0 then return {} end
    local size_results, probe_err = ftpSizeProbe(host, port, username, password, path, names)
    if not size_results then
        logger.warn("[ftp-dl] SIZE probe failed:", probe_err, "— extension heuristic fallback")
        local entries = {}
        for _, name in ipairs(names) do
            table.insert(entries, { name=name, is_dir=not name:match("%.%w+$") })
        end
        return entries
    end
    local entries = {}
    for _, name in ipairs(names) do
        local r = size_results[name]
        table.insert(entries, { name=name, is_dir=not r.is_file, size=r.is_file and r.size or nil })
    end
    return entries
end

local function ftpListEntries(host, port, username, password, path)
    local entries, err = ftpListEntriesMlsdList(host, port, username, password, path)
    if entries and #entries > 0 then return entries end
    logger.info("[ftp-dl] MLSD+LIST returned no results, trying NLST+SIZE:", err)
    return ftpListEntriesNlstSize(host, port, username, password, path)
end

-- ── File download ─────────────────────────────────────────────────────────────

local function ftpGetFile(host, port, username, password, remote_path, local_path)
    local ltn12 = require("ltn12")
    local f, err = io.open(local_path, "wb")
    if not f then return false, "cannot open local file: "..tostring(err) end
    local p = baseParams(host, port, username, password)
    p.path = remote_path; p.sink = ltn12.sink.file(f)
    local ok, dl_err = connDoGet(p)
    if not ok then
        pcall(function() f:close() end); pcall(function() os.remove(local_path) end)
        return false, dl_err
    end
    return true
end

-- ── Recursive folder download ─────────────────────────────────────────────────

local function mkdirs(path)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") then return end
    local parent = path:match("^(.+)/[^/]+$")
    if parent and parent~="" then mkdirs(parent) end
    lfs.mkdir(path)
end

local function downloadFolder(host, port, username, password, remote_path, local_path, progress)
    local lfs = require("libs/libkoreader-lfs")
    local ok_count, fail_count = 0, 0
    mkdirs(local_path)
    local entries, err = ftpListEntries(host, port, username, password, remote_path)
    if not entries then logger.warn("[ftp-dl] listing failed:", remote_path, err); return 0, 1 end
    for _, entry in ipairs(entries) do
        local r_child = remote_path:gsub("/$","").."/"..entry.name
        local l_child = local_path.."/"..entry.name
        if entry.is_dir then
            local a, b = downloadFolder(host, port, username, password, r_child, l_child, progress)
            ok_count=ok_count+a; fail_count=fail_count+b
        else
            local exists = lfs.attributes(l_child, "mode")
            if exists and get("on_conflict")=="skip" then
                ok_count=ok_count+1
                if progress then progress(true, entry.name, nil) end
            else
                if progress then progress(true, entry.name, entry.size) end
                local ok_dl, dl_err = ftpGetFile(host, port, username, password, r_child, l_child)
                if ok_dl then
                    ok_count=ok_count+1
                else
                    logger.warn("[ftp-dl] GET failed:", r_child, dl_err)
                    fail_count=fail_count+1
                end
            end
        end
    end
    return ok_count, fail_count
end

-- ── Size formatting ───────────────────────────────────────────────────────────

local function fmtSize(bytes)
    if not bytes then return "" end
    if bytes < 1024       then return ("%dB"):format(bytes) end
    if bytes < 1024*1024  then return ("%dKB"):format(math.floor(bytes/1024+0.5)) end
    if bytes < 1024^3     then return ("%dMB"):format(math.floor(bytes/(1024*1024)+0.5)) end
    return ("%.1fGB"):format(bytes/1024^3)
end


local function getDownloadDir()
    return (G_reader_settings and G_reader_settings:readSetting("lastdir")) or "/tmp"
end

-- ── Selection / browse dialog ─────────────────────────────────────────────────

local function showSelectionDialog(host, port, username, password,
                                   parent_remote_path, parent_local_name,
                                   base_dir, initial_entries, initial_page, is_public, index_delay)
    local UIManager       = require("ui/uimanager")
    local InfoMessage     = require("ui/widget/infomessage")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local Font            = require("ui/font")
    local Screen          = require("device").screen
    local Geom            = require("ui/geometry")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local RightContainer  = require("ui/widget/container/rightcontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local OverlapGroup    = require("ui/widget/overlapgroup")
    local Button          = require("ui/widget/button")
    local LineWidget      = require("ui/widget/linewidget")
    local Blitbuffer      = require("ffi/blitbuffer")

    local entries = initial_entries
    if not entries then
        local msg = InfoMessage:new{ text="Listing folder…" }
        UIManager:show(msg); UIManager:forceRePaint()
        local err
        entries, err = ftpListEntries(host, port, username, password, parent_remote_path)
        UIManager:close(msg); UIManager:forceRePaint()
        if not entries then
            UIManager:show(InfoMessage:new{
                text=("Listing failed: %s"):format(tostring(err)), timeout=5 })
            return
        end
        table.sort(entries, function(a, b)
            if a.is_dir ~= b.is_dir then return a.is_dir end
            if get("natural_sort") then return naturalLess(a.name, b.name) end
            return a.name:lower() < b.name:lower()
        end)
    end
    if #entries == 0 then
        UIManager:show(InfoMessage:new{ text="Folder is empty.", timeout=3 }); return
    end

    local function getConflictLbl() return get("on_conflict")=="skip" and "[S]" or "[O]" end
    local _dest = { dir = base_dir or getDownloadDir() }
    local function dl_dir() return _dest.dir end
    local function localPath(rp) local rel=rp:gsub("^/",""); return dl_dir()..(rel~="" and "/"..rel or "") end

    local nav_stack, cur_path, cur_name = {}, parent_remote_path, parent_local_name
    -- Cache root state for instant jump-to-root on long press
    local root_entries = entries
    local root_name    = parent_local_name
    local root_path    = parent_remote_path
    local selections   = {}
    local search_filter = ""  -- active search filter; "" means no filter
    local search_backup_entries = nil  -- backup of real entries during recursive search
    -- Per-server persistent index cache (stored in its own dedicated file)
    local function index_file_path()
        local safe_host = host:gsub("[^%w%.%-]", "_")
        return _DataStorage:getSettingsDir()
               .. "/ftp_index_" .. safe_host .. "_" .. tostring(port or 21) .. ".lua"
    end
    local function load_index()
        local s = _LuaSettings:open(index_file_path())
        return s:readSetting("index")
    end
    local function save_index(all)
        local s = _LuaSettings:open(index_file_path())
        s:saveSetting("index", all)
        s:saveSetting("ts", os.time())
        s:flush()
    end
    local function index_needs_refresh()
        local days = get("index_refresh_days")
        if days == 0 then return false end  -- never auto-refresh
        local s = _LuaSettings:open(index_file_path())
        local ts = s:readSetting("ts")
        if not ts then return true end  -- no index yet
        return (os.time() - ts) > (days * 86400)
    end
    local server_all_entries = nil  -- in-session cache (loaded from persistent on first use)

    local function filteredEntries()
        if search_filter == "" then return entries end
        local q = search_filter:lower()
        local result = {}
        for _, e in ipairs(entries) do
            if e.name:lower():find(q, 1, true) then
                table.insert(result, e)
            end
        end
        return result
    end

    local function entryPath(idx) return cur_path:gsub("/$","").."/"..entries[idx].name end
    local function isChecked(idx) return selections[entryPath(idx)] ~= nil end

    local _dir_count_cache = {}
    local function countFolderContents(path)
        if _dir_count_cache[path] then
            return _dir_count_cache[path].count, _dir_count_cache[path].sz
        end
        local es = ftpListEntries(host, port, username, password, path)
        if not es then return 0, 0 end
        local count, sz = 0, 0
        for _, e in ipairs(es) do
            if e.is_dir then
                local c, s = countFolderContents(path:gsub("/$","").."/"..e.name)
                count=count+c; sz=sz+s
            else count=count+1; sz=sz+(e.size or 0) end
        end
        _dir_count_cache[path] = { count=count, sz=sz }
        return count, sz
    end

    local function setChecked(idx, val)
        local path = entryPath(idx)
        if val then
            local e = entries[idx]
            local meta = { name=e.name, is_dir=e.is_dir, size=e.size }
            if e.is_dir then
                local msg = InfoMessage:new{ text="Counting \""..e.name.."\"…" }
                UIManager:show(msg); UIManager:forceRePaint()
                local count, sz = countFolderContents(path)
                UIManager:close(msg)
                meta.size=sz; meta.file_count=count
            end
            selections[path] = meta
        else selections[path]=nil end
    end
    local function toggleChecked(idx) setChecked(idx, not isChecked(idx)) end

    local small_face = Font:getFace("cfont", 16)
    local dialog_w   = Screen:getWidth()
    local dialog_h   = Screen:getHeight()
    local padding    = Screen:scaleBySize(8)
    local row_w      = dialog_w - padding*2

    local item_padding = Screen:scaleBySize(get("item_height"))

    local dialog_widget
    local dialog_widget
    local size_col_w = Button:new{ text="999MB", bordersize=0, padding=item_padding,
                                   text_font_face="cfont", text_font_size=16 }:getSize().w
    local name_btn_w = row_w - size_col_w
    local slot_btns, sep_widgets = {}, {}
    local count_btn, range_anchor, updateTitle, turnPage, back_btn, updateBackBtn
    local row_vg

    -- Button width percentage — computed first so dl_btn_w and all layout that
    -- depends on it (back_btn_w, _avail_nav, _page_label_avail, spacer) adapt.
    local _wpct        = get("bigger_buttons_width") / 100
    local dl_btn_w  = math.floor(Screen:scaleBySize(140) * 0.9 * _wpct)
    -- btn_row_w: full width inside the button row FrameContainers (padding=2 each side)
    local btn_row_w    = dialog_w - Screen:scaleBySize(2)*2
    local btn_right_pad = Screen:scaleBySize(4)  -- breathing room at right edge
    -- count_w: measure with exact same params as count_btn, plus safety margin
    local count_w   = Button:new{ text="9999/99.9GB>", bordersize=0, padding=0,
                                  face=small_face }:getSize().w + Screen:scaleBySize(4)
    -- back fills all remaining space; shrinks automatically on narrow screens
    local back_btn_w = math.max(0, btn_row_w - count_w - dl_btn_w - btn_right_pad)

    -- Button height scales true to percentage.
    -- Normal padding baseline = scaleBySize(4). We measure the height this produces,
    -- then scale that height by _pct and back-calculate the padding needed.
    local _pct         = get("bigger_buttons") / 100
    -- Scale btn_w down on narrow screens so page label always has minimum room.
    -- Use 30 raw pixels as minimum label width (works regardless of scaleBySize factor).
    local _min_label_w = 30
    local _gaps        = Screen:scaleBySize(4+4+2+2+2+2+4)  -- nav gaps + trailing gap
    local _avail_nav   = btn_row_w - dl_btn_w - btn_right_pad - _min_label_w - _gaps
    local _ideal_nav   = Screen:scaleBySize(70)*2 + Screen:scaleBySize(64)*4*0.81
    local _nav_scale   = (_ideal_nav > 0 and _avail_nav > 0)
                         and math.min(1.0, _avail_nav / _ideal_nav) or 1.0
    local back_font    = 16
    -- Calculate btn_padding first (needs _pct), then btn_w (needs btn_padding)
    local _base_pad    = Screen:scaleBySize(4)
    local _ref_w       = math.floor(Screen:scaleBySize(64) * _nav_scale)
    local _line_h      = Button:new{ text="Wg", width=math.max(1,_ref_w), padding=0,
                                     bordersize=0 }:getSize().h
    local _btn_h_base  = Button:new{ text="Wg", width=math.max(1,_ref_w),
                                     padding_top=_base_pad, padding_bottom=_base_pad,
                                     padding_left=Screen:scaleBySize(2),
                                     padding_right=Screen:scaleBySize(2) }:getSize().h
    local _target_h    = math.floor(_btn_h_base * _pct + 0.5)
    local btn_padding  = math.max(0, math.floor((_target_h - _line_h) / 2 + 0.5))
    -- Measure actual text widths needed so btn_w never squeezes text
    local _text_w_nav  = Button:new{ text="|‹", padding=0, bordersize=0 }:getSize().w
    local _text_w_wide = Button:new{ text="None", padding=0, bordersize=0 }:getSize().w
    local btn_w        = math.max(
                            math.floor(Screen:scaleBySize(64) * _nav_scale * 0.81 * _wpct),
                            2 * btn_padding + _text_w_nav)
    local btn_w_wide   = math.max(
                            math.floor(Screen:scaleBySize(70) * _nav_scale * _wpct),
                            2 * btn_padding + _text_w_wide)
    -- Measure actual btn_h
    local btn_h = Button:new{ text="Wg", width=btn_w, padding=btn_padding }:getSize().h

    -- Measure a single item slot height so we can fill the screen exactly
    local dummy_slot_h = Button:new{
        text="Wg", bordersize=0, padding=item_padding,
        text_font_face="cfont", text_font_size=get("item_font_size"),
    }:getSize().h + Screen:scaleBySize(1)  -- +1 for the separator LineWidget

    -- Fixed chrome: title + 2 separators + 2 button rows + their padding
    local title_h_approx    = Screen:scaleBySize(36) + padding*2 + Screen:scaleBySize(1)
    local btn_rows_h_approx = btn_h * 2 + Screen:scaleBySize(6) + Screen:scaleBySize(1)
    local chrome_h = title_h_approx + btn_rows_h_approx
    local avail_h  = dialog_h - chrome_h

    -- actual_per_page: never more than items_per_page setting, never more than fits
    local max_per_page    = math.max(1, math.floor(avail_h / dummy_slot_h))
    local actual_per_page = math.min(get("items_per_page"), max_per_page)

    local page_count = math.ceil(#(filteredEntries()) / actual_per_page)
    local page       = math.max(1, math.min(initial_page or 1, page_count))

    local function updateCount()
        if not count_btn then return end
        local n, sz = 0, 0
        for _, meta in pairs(selections) do
            n = n + (meta.file_count or 1)
            if meta.size then sz = sz + meta.size end
        end
        local sz_str = sz>0 and "/"..fmtSize(sz) or ""
        count_btn:setText(n..sz_str..">", count_btn.width); count_btn:refresh()
    end

    local function checkPrefix(idx)
        if idx==range_anchor then return isChecked(idx) and "‹✓ " or "› " end
        return isChecked(idx) and "✓ " or ""
    end

    local function updateSlots(p)
        local visible  = filteredEntries()
        local f        = (p-1)*actual_per_page+1
        local sl       = math.min(actual_per_page, #visible-(p-1)*actual_per_page)
        local truncate = not get("selection_shrink")
        while #row_vg>0 do table.remove(row_vg) end
        slot_btns, sep_widgets = {}, {}
        for slot = 1, sl do
            local idx      = f+slot-1
            local entry    = visible[idx]
            -- find real index in entries[] for selection tracking
            local real_idx = idx
            if search_filter ~= "" then
                for ri, e in ipairs(entries) do
                    if e == entry then real_idx = ri; break end
                end
            end
            local prefix   = entry and checkPrefix(real_idx) or ""
            local icon     = (entry and entry.is_dir) and "▶ " or ""
            local size_str = (entry and not entry.is_dir and entry.size)
                             and fmtSize(entry.size):gsub("^ ","") or ""
            local name_str = entry and (prefix..icon..entry.name) or ""
            local nbtn = Button:new{
                text=truncate and "" or name_str, align="left", width=name_btn_w,
                bordersize=0, padding=item_padding,
                text_font_face="cfont", text_font_size=get("item_font_size"), text_font_bold=false,
                hold_callback=function()
                    local vis=filteredEntries()
                    local ri_vis=(page-1)*actual_per_page+slot
                    local e_vis=vis[ri_vis]; if not e_vis then return end
                    local ri=ri_vis
                    if search_filter~="" then for i,e in ipairs(entries) do if e==e_vis then ri=i; break end end end
                    if range_anchor==ri then range_anchor=nil; updateSlots(page); return end
                    toggleChecked(ri); updateSlots(page)
                end,
                callback=function()
                    local vis=filteredEntries()
                    local ri_vis=(page-1)*actual_per_page+slot
                    local e_vis2=vis[ri_vis]; if not e_vis2 then return end
                    local ri=ri_vis
                    if search_filter~="" then for i,e2 in ipairs(entries) do if e2==e_vis2 then ri=i; break end end end
                    if not entries[ri] then return end
                    local e=entries[ri]
                    if e.is_dir then
                        local sub_path=cur_path:gsub("/$","").."/"..e.name
                        local sub_entries, err=ftpListEntries(host,port,username,password,sub_path)
                        if not sub_entries then
                            UIManager:show(InfoMessage:new{
                                text="Listing failed: "..tostring(err), timeout=4 }); return
                        end
                        table.sort(sub_entries, function(a,b)
                            if a.is_dir~=b.is_dir then return a.is_dir end
                            if get("natural_sort") then return naturalLess(a.name,b.name) end
                            return a.name:lower()<b.name:lower()
                        end)
                        table.insert(nav_stack,{path=cur_path,name=cur_name,entries=entries,page=page,
                            search_filter=search_filter,search_backup_entries=search_backup_entries})
                        cur_path=sub_path; cur_name=e.name; entries=sub_entries
                        range_anchor=nil; search_filter=""; search_backup_entries=nil; page_count=math.ceil(#(filteredEntries())/actual_per_page)
                        turnPage(1)
                        if updateTitle then updateTitle() end
                        if updateBackBtn then updateBackBtn() end
                        return
                    end
                    if range_anchor==ri then range_anchor=nil; updateSlots(page); return end
                    toggleChecked(ri)
                    if truncate then
                        slot_btns[slot]:setText(checkPrefix(ri)..(e.is_dir and "▶ " or "")..e.name, name_btn_w)
                        slot_btns[slot]:refresh(); updateCount(); UIManager:setDirty(dialog_widget,"ui")
                    else updateSlots(page) end
                end,
            }
            if truncate then nbtn:setText(name_str, name_btn_w) end
            local sbtn = Button:new{
                text=size_str, align="right", width=size_col_w,
                bordersize=0, padding=item_padding, text_font_face="cfont", text_font_size=16, text_font_bold=false,
                callback=function()
                    local vis=filteredEntries()
                    local ri_vis=(page-1)*actual_per_page+slot
                    local e_svis=vis[ri_vis]; if not e_svis then return end
                    local ri=ri_vis
                    if search_filter~="" then for i,e2 in ipairs(entries) do if e2==e_svis then ri=i; break end end end
                    if not entries[ri] then return end
                    if range_anchor==nil then range_anchor=ri; updateSlots(page)
                    elseif range_anchor==ri then range_anchor=nil; updateSlots(page)
                    else
                        local a,b=math.min(range_anchor,ri),math.max(range_anchor,ri)
                        local target=not isChecked(range_anchor)
                        for i=a,b do setChecked(i,target) end
                        range_anchor=nil; updateSlots(page)
                    end
                end,
            }
            slot_btns[slot]=nbtn
            table.insert(row_vg, HorizontalGroup:new{align="center", nbtn, sbtn})
            local sep=LineWidget:new{dimen=Geom:new{w=row_w,h=Screen:scaleBySize(1)}}
            sep_widgets[slot]=sep; table.insert(row_vg, sep)
        end
        updateCount(); if updateTitle then updateTitle() end
        UIManager:setDirty(dialog_widget, "ui")
    end

    row_vg = VerticalGroup:new{ allow_mirroring=false }
    updateSlots(page)

    local btn_prev, btn_next, btn_first, btn_last, page_label_btn

    local function refreshNavButtons()
        if not btn_prev then return end
        if page>1 then btn_prev:enable(); btn_first:enable()
        else btn_prev:disable(); btn_first:disable() end
        if page<page_count then btn_next:enable(); btn_last:enable()
        else btn_next:disable(); btn_last:disable() end
        page_label_btn:setText(("%d / %d"):format(page,page_count), page_label_btn.width)
        page_label_btn:refresh()
        btn_prev:refresh(); btn_next:refresh(); btn_first:refresh(); btn_last:refresh()
    end

    turnPage = function(new_page)
        page=new_page; updateSlots(page); refreshNavButtons()
    end

    local function setPageChecked(state)
        local vis=filteredEntries(); local f=(page-1)*actual_per_page+1; local l=math.min(page*actual_per_page,#vis)
        for i=f,l do
            local ev=vis[i]; if ev then
                local ri=i
                if search_filter~="" then for ri2,e2 in ipairs(entries) do if e2==ev then ri=ri2; break end end end
                setChecked(ri,state)
            end
        end; updateSlots(page)
    end

    local function doDownload()
        local selected = {}
        for path, meta in pairs(selections) do
            table.insert(selected,{name=meta.name,is_dir=meta.is_dir,size=meta.size,url=path})
        end
        if #selected==0 then
            UIManager:show(InfoMessage:new{text="Nothing selected.",timeout=3}); return
        end
        local lfs=require("libs/libkoreader-lfs")
        local total_ok,total_fail,total_skip,total_dl=0,0,0,0
        local total_files=0
        for _,meta in pairs(selections) do
            total_files=total_files+(meta.file_count or (meta.is_dir and 0 or 1))
        end
        local cur_msg=InfoMessage:new{text="Downloading..."}
        UIManager:show(cur_msg); UIManager:forceRePaint()
        local _last_repaint = 0
        local function showProgress(filename, size)
            local now = os.time()
            if now - _last_repaint < 2 then return end
            _last_repaint = now
            local new_text = ("%d/%d downloaded%s, %d failed\n\u{2193} %s %s"):format(
                total_ok, total_files,
                total_skip>0 and (", %d skipped"):format(total_skip) or "",
                total_fail, filename, fmtSize(size))
            if cur_msg and cur_msg.text_widget then
                cur_msg.text_widget:setText(new_text)
                UIManager:setDirty(cur_msg, "ui")
                UIManager:forceRePaint()
            else
                if cur_msg then UIManager:close(cur_msg) end
                cur_msg=InfoMessage:new{text=new_text}
                UIManager:show(cur_msg); UIManager:forceRePaint()
            end
        end
        local failed_urls={}
        for _,entry in ipairs(selected) do
            local r_child=entry.url
            local l_child=get("keep_structure") and localPath(entry.url) or (dl_dir().."/"..entry.name)
            if entry.is_dir then
                local entry_fail=0
                xpcall(function()
                    downloadFolder(host,port,username,password,r_child,l_child,function(success,filename,size)
                        if success and size then total_ok=total_ok+1; total_dl=total_dl+1
                        elseif success then total_skip=total_skip+1; total_ok=total_ok+1
                        else total_fail=total_fail+1; entry_fail=entry_fail+1 end
                        showProgress(filename,size)
                    end)
                end, function(e) logger.err("[ftp-dl]",e); entry_fail=entry_fail+1 end)
                if entry_fail>0 then failed_urls[entry.url]=true end
            else
                local parent_dir=l_child:match("^(.+)/[^/]+$")
                if parent_dir then mkdirs(parent_dir) end
                local exists=lfs.attributes(l_child,"mode")
                if exists and get("on_conflict")=="skip" then
                    total_skip=total_skip+1; total_ok=total_ok+1; showProgress(entry.name,entry.size)
                else
                    showProgress(entry.name,entry.size)
                    local ok_dl=ftpGetFile(host,port,username,password,r_child,l_child)
                    if ok_dl then total_ok=total_ok+1; total_dl=total_dl+1
                    else total_fail=total_fail+1; failed_urls[entry.url]=true end
                end
            end
        end
        if cur_msg then UIManager:close(cur_msg) end
        for _,entry in ipairs(selected) do
            if not failed_urls[entry.url] then
                selections[entry.url]=nil
                -- also clear by name match for search results where path may differ
                for k,v in pairs(selections) do
                    if v.name==entry.name and not failed_urls[entry.url] then selections[k]=nil end
                end
            end
        end
        updateSlots(page); updateCount(); UIManager:setDirty(dialog_widget,"ui")
        _dest.dir=base_dir  -- reset temporary override back to permanent folder
        UIManager:show(InfoMessage:new{
            text=("Done. %d saved%s, %d failed\n-> %s"):format(
                total_dl, total_skip>0 and (", %d skipped"):format(total_skip) or "",
                total_fail, dl_dir()),
            timeout=6,
        })
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then FileManager.instance:onRefresh() end
    end

    -- ── Top button row: All  None  |‹  ‹  [page]  ›  ›|  [Download to right-pinned]
    -- OverlapGroup + RightContainer pins "Download to" flush right regardless of
    -- what the left side does — zero alignment math, immune to scaleBySize rounding.

    -- page_label fills from end of nav buttons up to where Download to starts.
    -- Individual scaleBySize calls match actual button widths; avoids rounding drift.
    local _vpad = btn_padding

    local nav_fixed =
        btn_w_wide + Screen:scaleBySize(4) +   -- All + gap
        btn_w_wide + Screen:scaleBySize(4) +   -- None + gap
        btn_w      + Screen:scaleBySize(2) +   -- |‹ + gap
        btn_w      + Screen:scaleBySize(2) +   -- ‹ + gap
        Screen:scaleBySize(2) + btn_w      +   -- gap + ›
        Screen:scaleBySize(2) + btn_w          -- gap + ›|
    local _page_label_avail = btn_row_w - dl_btn_w - btn_right_pad - nav_fixed - Screen:scaleBySize(4)
    -- Use 30 raw pixels minimum — safe regardless of scaleBySize factor
    local page_label_w      = math.max(30, _page_label_avail)
    page_label_btn=Button:new{
        text=("%d / %d"):format(page,page_count), width=page_label_w,
        bordersize=0, padding=0, enabled=page_count>1,
        callback=function()
            local InputDialog=require("ui/widget/inputdialog"); local dlg
            dlg=InputDialog:new{
                title="Go to page", input="", input_type="number",
                buttons={{
                    {text="Cancel",callback=function() UIManager:close(dlg) end},
                    {text="Go",is_enter_default=true,callback=function()
                        local n=tonumber(dlg:getInputText()); UIManager:close(dlg)
                        if n then turnPage(math.max(1,math.min(n,page_count))) end
                    end},
                }},
            }
            UIManager:show(dlg); dlg:onShowKeyboard()
        end,
    }
    btn_first=Button:new{text="|‹",width=btn_w,padding=_vpad,
                         enabled=page>1, callback=function() turnPage(1) end}
    btn_last =Button:new{text="›|",width=btn_w,padding=_vpad,
                         enabled=page<page_count, callback=function() turnPage(page_count) end}
    btn_prev =Button:new{text="‹", width=btn_w,padding=_vpad,
                         enabled=page>1, callback=function() turnPage(page-1) end}
    btn_next =Button:new{text="›", width=btn_w,padding=_vpad,
                         enabled=page<page_count, callback=function() turnPage(page+1) end}

    local function openDownloadToChooser()
        local PathChooser=require("ui/widget/pathchooser")
        local cfg_key="ftp_base_dir_"..host
        UIManager:show(PathChooser:new{
            select_directory=true, select_file=false, show_files=false, path=_dest.dir,
            onConfirm=function(dir)
                _dest.dir=dir; base_dir=dir
                set(cfg_key, dir)
            end,
        })
    end

    local top_btn_row = OverlapGroup:new{
        dimen = Geom:new{ w=btn_row_w, h=btn_h },
        -- left: All None pagination
        HorizontalGroup:new{
            align="center",
            Button:new{text="All", width=btn_w_wide, padding=_vpad,
                callback=function() setPageChecked(true) end,
                hold_callback=function() for i=1,#entries do setChecked(i,true) end; updateSlots(page) end},
            HorizontalSpan:new{width=Screen:scaleBySize(4)},
            Button:new{text="None", width=btn_w_wide, padding=_vpad,
                callback=function() setPageChecked(false) end,
                hold_callback=function() for i=1,#entries do setChecked(i,false) end; updateSlots(page) end},
            HorizontalSpan:new{width=Screen:scaleBySize(4)},
            btn_first, HorizontalSpan:new{width=Screen:scaleBySize(2)},
            btn_prev,  HorizontalSpan:new{width=Screen:scaleBySize(2)},
            page_label_btn, HorizontalSpan:new{width=Screen:scaleBySize(2)},
            btn_next,  HorizontalSpan:new{width=Screen:scaleBySize(2)},
            btn_last,
        },
        -- right: spacer pushes Download to flush right; same HorizontalGroup/align
        -- as left so vertical positioning is identical — no RightContainer weirdness
        HorizontalGroup:new{
            align="center",
            HorizontalSpan:new{ width=btn_row_w - dl_btn_w - btn_right_pad },
            Button:new{
                text="Save to /", width=dl_btn_w, padding=_vpad,
                callback=openDownloadToChooser,
            },
        },
    }

    -- ── Bottom row: [Server [S/O] / ↑ Parent]  Download  >count ─────────────

    local function goToRoot()
        if #nav_stack==0 and search_filter=="" then return end  -- already at root with no filter
        local root_page = #nav_stack>0 and nav_stack[1].page or page
        nav_stack = {}
        cur_path = root_path; cur_name = root_name; entries = root_entries
        search_filter = ""; search_backup_entries = nil
        page_count = math.ceil(#(filteredEntries())/actual_per_page); range_anchor = nil
        turnPage(math.min(root_page, page_count))
        if updateTitle then updateTitle() end
        if updateBackBtn then updateBackBtn() end
    end

    back_btn=Button:new{
        text="", align="left", width=back_btn_w,
        bordersize=0, padding=_vpad,
        face=small_face, text_font_bold=true,
        callback=function()
            if #nav_stack==0 then
                -- At root: toggle skip/overwrite
                local new_conflict=get("on_conflict")=="skip" and "overwrite" or "skip"
                set("on_conflict", new_conflict)
                if updateBackBtn then updateBackBtn() end
                if updateTitle then updateTitle() end
            else
                -- In subfolder: navigate up one level
                local prev=table.remove(nav_stack)
                cur_path=prev.path; cur_name=prev.name; entries=prev.entries
                search_filter=prev.search_filter or ""
                search_backup_entries=prev.search_backup_entries or nil
                page_count=math.ceil(#(filteredEntries())/actual_per_page); range_anchor=nil
                turnPage(math.min(prev.page,page_count))
                if updateTitle then updateTitle() end
                if updateBackBtn then updateBackBtn() end
            end
        end,
        hold_callback=function()
            goToRoot()
        end,
    }

    updateBackBtn=function()
        if not back_btn then return end
        local txt
        if #nav_stack==0 then
            txt=cur_name.."  "..getConflictLbl()
        else
            txt="<< "..cur_name
        end
        back_btn:setText(txt, back_btn_w)
        back_btn:refresh()
    end
    updateBackBtn()

    -- Bottom row: [back] [count>] [Download] — back anchored to far left
    count_btn=Button:new{text="0>", width=count_w, align="right",
                         bordersize=0, padding=0, face=small_face}
    local bottom_btn_row=HorizontalGroup:new{
        align="center",
        back_btn,
        count_btn,
        Button:new{
            text="Download", width=dl_btn_w,
            padding=_vpad,
            callback=doDownload,
            hold_callback=function()
                -- Temporary folder override for this download only.
                -- doDownload resets _dest.dir to base_dir after finishing.
                local PathChooser=require("ui/widget/pathchooser")
                UIManager:show(PathChooser:new{
                    select_directory=true, select_file=false, show_files=false, path=dl_dir(),
                    onConfirm=function(dir) _dest.dir=dir end,
                })
            end,
        },
    }

    local title_h=Screen:scaleBySize(36)
    local function titleText()
        local back=#nav_stack>0 and "<< " or ""
        local filter_str = search_filter~="" and ("  [/"..search_filter.."]") or ""
        if range_anchor then
            local anchor_name=entries[range_anchor] and entries[range_anchor].name or ""
            local anchor_mark=isChecked(range_anchor) and "‹" or "›"
            return ('%s"%s"  %s  %s%d: %s%s'):format(back,cur_name,getConflictLbl(),anchor_mark,range_anchor,anchor_name,filter_str)
        end
        return ('%s"%s"  %s%s'):format(back,cur_name,getConflictLbl(),filter_str)
    end
    local title_text_btn=Button:new{
        text=titleText(), align="left", face=small_face,
        width=dialog_w-padding*2-Screen:scaleBySize(48)*2, height=Screen:scaleBySize(44), bordersize=0, padding=0,
        callback=function()
            if #nav_stack==0 then
                -- At root: toggle skip/overwrite (mirrors bottom back button)
                local new_conflict=get("on_conflict")=="skip" and "overwrite" or "skip"
                set("on_conflict", new_conflict)
                if updateBackBtn then updateBackBtn() end
                if updateTitle then updateTitle() end
            else
                -- In subfolder: navigate up one level
                local prev=table.remove(nav_stack)
                cur_path=prev.path; cur_name=prev.name; entries=prev.entries
                search_filter=prev.search_filter or ""
                search_backup_entries=prev.search_backup_entries or nil
                page_count=math.ceil(#(filteredEntries())/actual_per_page); range_anchor=nil
                turnPage(math.min(prev.page,page_count))
                if updateTitle then updateTitle() end
                if updateBackBtn then updateBackBtn() end
            end
        end,
        hold_callback=function()
            goToRoot()
        end,
    }
    updateTitle=function()
        title_text_btn:setText(titleText(),title_text_btn.width); title_text_btn:refresh()
    end

    -- Recursive FTP search: collect all matching entries from server
    local function ftpSearchRecursive(path, query, results, msg_ref)
        local socket = require("socket")
        local es = ftpListEntries(host, port, username, password, path)
        if not es then return end
        for _, e in ipairs(es) do
            local full_path = path:gsub("/$","").."/"..e.name
            if query == "" or e.name:lower():find(query, 1, true) then
                table.insert(results, {
                    name    = full_path,
                    is_dir  = e.is_dir,
                    size    = e.size,
                    _path   = full_path,
                })
            end
            if e.is_dir then
                if is_public then socket.sleep(index_delay or 0.5) end
                ftpSearchRecursive(full_path, query, results, msg_ref)
            end
        end
    end

    local IconButton = require("ui/widget/iconbutton")
    local function onSearchBtn()
            if search_filter ~= "" then
                -- clear filter and restore real entries
                search_filter = ""
                if search_backup_entries then
                    entries = search_backup_entries
                    search_backup_entries = nil
                end
                page_count = math.ceil(#(filteredEntries())/actual_per_page)
                turnPage(math.min(page, math.max(1,page_count)))
                if updateTitle then updateTitle() end
            else
                local InputDialog  = require("ui/widget/inputdialog")
                local CheckButton  = require("ui/widget/checkbutton")
                local do_reindex   = get("index_always_reindex") or index_needs_refresh()
                local ref = {}
                ref.dlg = InputDialog:new{
                    title      = "Search",
                    input      = "",
                    input_type = "text",
                    buttons = {{
                        { text="Cancel", callback=function() UIManager:close(ref.dlg) end },
                        { text="Search", is_enter_default=true, callback=function()
                            local q = ref.dlg:getInputText()
                            if q == "" then UIManager:close(ref.dlg); return end
                            UIManager:close(ref.dlg)
                            local lq = q:lower()
                            -- Build or refresh index if needed
                            if not server_all_entries or do_reindex then
                                local msg = InfoMessage:new{ text="Indexing server..." }
                                UIManager:show(msg); UIManager:forceRePaint()
                                local all = {}
                                ftpSearchRecursive(root_path, "", all)
                                UIManager:close(msg); UIManager:forceRePaint()
                                server_all_entries = all
                                save_index(all)
                            end
                            local results = {}
                            for _, e in ipairs(server_all_entries) do
                                if e.name:lower():find(lq, 1, true) then
                                    table.insert(results, e)
                                end
                            end
                            if #results == 0 then
                                UIManager:show(InfoMessage:new{
                                    text='No results for "'..q..'"', timeout=3 })
                                return
                            end
                            table.sort(results, function(a,b)
                                if a.is_dir ~= b.is_dir then return a.is_dir end
                                if get("natural_sort") then return naturalLess(a.name, b.name) end
                                return a.name:lower() < b.name:lower()
                            end)
                            search_backup_entries = entries
                            entries = results
                            search_filter = q
                            page_count = math.ceil(#entries/actual_per_page)
                            turnPage(1)
                            if updateTitle then updateTitle() end
                        end },
                    }},
                }
                -- Checkbox: re-index contents
                local cb
                cb = CheckButton:new{
                    text    = "Re-index contents",
                    checked = do_reindex,
                    callback = function()
                        do_reindex = cb.checked
                        set("index_always_reindex", cb.checked)
                    end,
                    parent = ref.dlg,
                }
                ref.dlg:addWidget(cb)
                -- Load persistent index into session cache if available and not stale
                if not server_all_entries and not index_needs_refresh() then
                    server_all_entries = load_index()
                end
                UIManager:show(ref.dlg); ref.dlg:onShowKeyboard()
            end
    end
    local title_row=OverlapGroup:new{
        dimen=Geom:new{w=dialog_w-padding*2,h=title_h},
        title_text_btn,
        RightContainer:new{
            dimen=Geom:new{w=dialog_w-padding*2,h=title_h},
            [1]=HorizontalGroup:new{
                align="center",
                -- wrap IconButton in same-size container as ✕ button
                FrameContainer:new{
                    width=Screen:scaleBySize(44), height=Screen:scaleBySize(44),
                    padding_left=0, padding_right=0,
                    padding_top=0, padding_bottom=0,
                    bordersize=0,
                    CenterContainer:new{
                        dimen=Geom:new{
                            w=Screen:scaleBySize(44),
                            h=Screen:scaleBySize(44),
                        },
                        [1]=IconButton:new{
                            icon = "appbar.search",
                            width  = Screen:scaleBySize(36),
                            height = Screen:scaleBySize(36),
                            callback = onSearchBtn,
                        },
                    },
                },
                Button:new{
                    text="✕",width=Screen:scaleBySize(44),height=Screen:scaleBySize(44),padding=0,bordersize=0,
                    text_font_face="cfont", text_font_size=36, text_font_bold=false,
                    callback=function()
                        UIManager:close(dialog_widget); UIManager:setDirty(nil,"full"); pcall(closePool)
                    end,
                },
            },
        },
    }

    local inner=VerticalGroup:new{
        align="left",
        FrameContainer:new{padding=padding,bordersize=0,[1]=title_row},
        LineWidget:new{dimen=Geom:new{w=dialog_w,h=Screen:scaleBySize(1)}},
        FrameContainer:new{padding_top=0,padding_left=padding,padding_right=padding,
                           padding_bottom=0,bordersize=0,
                           height=avail_h,[1]=row_vg},
        LineWidget:new{dimen=Geom:new{w=dialog_w,h=Screen:scaleBySize(1)}},
        FrameContainer:new{padding_top=Screen:scaleBySize(2),padding_bottom=0,
                           padding_left=Screen:scaleBySize(2),padding_right=Screen:scaleBySize(2),
                           bordersize=0,[1]=top_btn_row},
        FrameContainer:new{padding_top=Screen:scaleBySize(2),padding_bottom=Screen:scaleBySize(2),
                           padding_left=Screen:scaleBySize(2),padding_right=Screen:scaleBySize(2),
                           bordersize=0,[1]=bottom_btn_row},
    }
    dialog_widget=FrameContainer:new{
        background=Blitbuffer.COLOR_WHITE,radius=0,
        padding=0,width=dialog_w,height=dialog_h,[1]=inner,
    }
    UIManager:show(dialog_widget)
end

-- ── Server add / edit ─────────────────────────────────────────────────────────
-- Each step is a fresh dialog created on demand so we never reshow a closed
-- (and internally freed) widget, which would crash on _bb being nil.

local function showAddEditServerDialog(existing, on_save)
    local UIManager   = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")

    local result = {
        name         = existing and existing.name         or "",
        address      = existing and existing.address      or "",
        username     = existing and existing.username     or "",
        password     = existing and existing.password     or "",
        is_public    = existing and existing.is_public    or false,
        index_delay  = existing and existing.index_delay  or 0.5,
    }

    local showStep  -- forward ref

    local steps = {
        {
            title      = "Server name",
            field      = "name",
            input_type = "text",
            required   = true,
            prev       = nil,
            next       = 2,
        },
        {
            title      = "Address  (host  or  host:port)",
            field      = "address",
            input_type = "text",
            required   = false,
            prev       = 1,
            next       = 3,
        },
        {
            title      = "Username (leave blank for anonymous)",
            field      = "username",
            input_type = "text",
            required   = false,
            prev       = 2,
            next       = 4,
        },
        {
            title      = "Password (leave blank if none)",
            field      = "password",
            input_type = "text",
            text_type  = "password",
            required   = false,
            prev       = 3,
            next       = nil,  -- last step: Save (or step 5 if public)
        },
    }

    -- Step 5: delay spinner, shown only when is_public is true
    local function showDelayStep(on_done)
        local SpinWidget = require("ui/widget/spinwidget")
        UIManager:show(SpinWidget:new{
            title_text  = "Indexing delay between folders (seconds)",
            value       = result.index_delay,
            value_min   = 0.1,
            value_max   = 5.0,
            value_step  = 0.1,
            precision   = "%.1f",
            ok_text     = "Save",
            cancel_text = "Back",
            callback    = function(sw)
                result.index_delay = sw.value
                on_done()
            end,
            cancel_callback = function()
                -- Back to step 4
                showStep(4)
            end,
        })
    end

    showStep = function(idx)
        local step  = steps[idx]
        local is_last = step.next == nil
        -- ref.dlg is assigned after InputDialog:new so closures can reach it
        local ref = {}
        local buttons = {}
        if step.prev then
            table.insert(buttons, {
                text = "Back",
                callback = function()
                    result[step.field] = ref.dlg:getInputText()
                    UIManager:close(ref.dlg)
                    showStep(step.prev)
                end,
            })
        else
            table.insert(buttons, {
                text = "Cancel",
                callback = function() UIManager:close(ref.dlg) end,
            })
        end
        table.insert(buttons, {
            text = is_last and (result.is_public and "Next" or "Save") or "Next",
            is_enter_default = true,
            callback = function()
                local val = ref.dlg:getInputText()
                if step.required and val == "" then return end
                result[step.field] = val
                UIManager:close(ref.dlg)
                if is_last then
                    if result.is_public then
                        showDelayStep(function() on_save(result) end)
                    else
                        on_save(result)
                    end
                else
                    showStep(step.next)
                end
            end,
        })

        ref.dlg = InputDialog:new{
            title      = step.title,
            input      = result[step.field],
            input_type = step.input_type,
            text_type  = step.text_type,
            buttons    = { buttons },
        }
        if is_last then
            local CheckButton = require("ui/widget/checkbutton")
            local cb
            cb = CheckButton:new{
                text     = "Public server (rate-limit indexing)",
                checked  = result.is_public,
                callback = function()
                    result.is_public = cb.checked
                    -- Update Save/Next label to reflect whether delay step follows
                    local new_text = result.is_public and "Next" or "Save"
                    -- Re-render the button text by rebuilding the dialog isn't
                    -- practical here; the label updates on next open. Acceptable
                    -- since the checkbox state is clear from the tick itself.
                end,
                parent   = ref.dlg,
            }
            ref.dlg:addWidget(cb)
        end
        UIManager:show(ref.dlg)
        ref.dlg:onShowKeyboard()
    end

    showStep(1)
end

-- ── Server list dialog ────────────────────────────────────────────────────────

local function showServerListDialog()
    local UIManager    = require("ui/uimanager")
    local InfoMessage  = require("ui/widget/infomessage")
    local ButtonDialog = require("ui/widget/buttondialog")

    local function openServer(server)
        local NetworkMgr = require("ui/network/manager")
        if NetworkMgr.isOnline and not NetworkMgr:isOnline() then
            NetworkMgr:beforeWifiAction(function() openServer(server) end); return
        end
        local host, port = parseAddress(server.address or "")
        local username   = server.username or ""
        local password   = server.password or ""
        local is_public  = server.is_public or false
        local index_delay = server.index_delay or 0.5
        local cfg_key    = "ftp_base_dir_"..host
        local saved_dir  = get(cfg_key)
        if not saved_dir or saved_dir=="" then
            local PathChooser=require("ui/widget/pathchooser")
            UIManager:show(InfoMessage:new{
                text="Choose a base download folder for \""..server.name.."\"\nThis will be remembered.",
                timeout=3,
            })
            UIManager:forceRePaint()
            UIManager:show(PathChooser:new{
                select_directory=true, select_file=false, show_files=false,
                path=getDownloadDir(),
                onConfirm=function(dir)
                    set(cfg_key, dir)
                    showSelectionDialog(host, port, username, password, "/", server.name, dir, nil, nil, is_public, index_delay)
                end,
            })
        else
            showSelectionDialog(host, port, username, password, "/", server.name, saved_dir, nil, nil, is_public, index_delay)
        end
    end

    local dialog
    local function rebuild()
        if dialog then UIManager:close(dialog) end
        local servers = getServers()
        local buttons = {}

        for i, server in ipairs(servers) do
            local s   = server
            local idx = i
            table.insert(buttons, {{
                text          = s.name.."  (".. (s.address or "") ..")",
                align         = "left",
                callback      = function() UIManager:close(dialog); openServer(s) end,
                hold_callback = function()
                    local opts
                    opts = ButtonDialog:new{
                        title   = s.name,
                        buttons = {
                            {{ text="Edit", callback=function()
                                UIManager:close(opts)
                                showAddEditServerDialog(s, function(updated)
                                    local svrs=getServers(); svrs[idx]=updated
                                    saveServers(svrs); rebuild()
                                end)
                            end}},
                            {{ text="Delete", callback=function()
                                UIManager:close(opts)
                                local svrs=getServers(); table.remove(svrs, idx)
                                saveServers(svrs); rebuild()
                            end}},
                            {{ text="Cancel", callback=function() UIManager:close(opts) end}},
                        },
                    }
                    UIManager:show(opts)
                end,
            }})
        end

        table.insert(buttons, {{
            text     = "＋  Add server",
            callback = function()
                UIManager:close(dialog)
                showAddEditServerDialog(nil, function(new_server)
                    local svrs=getServers(); table.insert(svrs, new_server)
                    saveServers(svrs); rebuild()
                end)
            end,
        }})
        table.insert(buttons, {{
            text="Close", callback=function() UIManager:close(dialog) end,
        }})

        dialog = ButtonDialog:new{
            title   = #servers>0 and "FTP Servers  (hold to edit/delete)" or "FTP Servers  — no servers yet",
            buttons = buttons,
        }
        UIManager:show(dialog)
    end

    rebuild()
end

-- ── Plugin lifecycle ──────────────────────────────────────────────────────────

function FTPDownloadManager:onDispatcherRegisterActions()
    Dispatcher:registerAction("ftp_browse_servers", {
        category = "none",
        event    = "FTPBrowseServers",
        title    = "FTP Download Manager: Browse servers",
        general  = true,
    })
end

function FTPDownloadManager:onFTPBrowseServers()
    showServerListDialog()
end

function FTPDownloadManager:onSuspend()
    -- Device going to sleep: close pool while wifi is still up (or nearly so)
    pcall(closePool)
end

function FTPDownloadManager:onResume()
    -- Force full repaint after wake so dialog isn't frozen
    local UIManager = require("ui/uimanager")
    UIManager:setDirty(nil, "full")
    UIManager:forceRePaint()
end

function FTPDownloadManager:onNetworkDisconnected()
    -- Wifi dropped (sleep, manual toggle, etc): dead connections are useless
    pcall(closePool)
end

function FTPDownloadManager:init()
    self:onDispatcherRegisterActions()
end

-- ── Inject into AI Slop Settings in the filing-cabinet menu ───────────────────

local _ftp_menu_hooked = false
local orig_setUpdateItemTable = FileManagerMenu.setUpdateItemTable

function FileManagerMenu:setUpdateItemTable()
    if not _ftp_menu_hooked then
        _ftp_menu_hooked = true

        -- Ensure ai_slop_settings exists in the filing-cabinet Settings tab
        if type(FileManagerMenuOrder.filemanager_settings) == "table" then
            local found = false
            for _, k in ipairs(FileManagerMenuOrder.filemanager_settings) do
                if k == "ai_slop_settings" then found = true; break end
            end
            if not found then
                table.insert(FileManagerMenuOrder.filemanager_settings, 1, "ai_slop_settings")
            end
        end

        -- Create ai_slop_settings parent if not already created by another patch
        if not self.menu_items.ai_slop_settings then
            self.menu_items.ai_slop_settings = {
                text = "AI Slop Settings",
                sub_item_table = {},
            }
        end

        -- Insert FTP DM at position 1 (guard against duplicate injection)
        local already = false
        for _, item in ipairs(self.menu_items.ai_slop_settings.sub_item_table) do
            if item._ftp_dl_entry then already = true; break end
        end
        if not already then
            table.insert(self.menu_items.ai_slop_settings.sub_item_table, 1, {
                _ftp_dl_entry = true,
                text = "FTP Download Manager",
                sub_item_table = {
            {
                text     = "Browse servers",
                callback = function() showServerListDialog() end,
            },
            { text="─────────────────────", enabled=false },
            {
                text         = "Prioritize FTPS",
                checked_func = function() return get("prefer_ftps") end,
                callback     = function() set("prefer_ftps", not get("prefer_ftps")) end,
            },
            {
                text         = "Natural sorting (1, 2, 10)",
                checked_func = function() return get("natural_sort") end,
                callback     = function() set("natural_sort", not get("natural_sort")) end,
            },
            {
                text         = "Shrink long names to fit",
                checked_func = function() return get("selection_shrink") end,
                callback     = function() set("selection_shrink", not get("selection_shrink")) end,
            },
            {
                text         = "Always keep folder structure",
                checked_func = function() return get("keep_structure") end,
                callback     = function() set("keep_structure", not get("keep_structure")) end,
            },
            {
                text_func = function()
                    local d = get("index_refresh_days")
                    return "Auto refresh file index: " .. (d == 0 and "never" or d.." day"..(d==1 and "" or "s"))
                end,
                keep_menu_open = true,
                callback = function(tmi)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local UIManager  = require("ui/uimanager")
                    UIManager:show(SpinWidget:new{
                        title_text  = "Auto refresh file index (days, 0=never)",
                        value       = get("index_refresh_days"),
                        value_min   = 0,
                        value_max   = 90,
                        value_step  = 1,
                        ok_text     = "Set",
                        callback    = function(sw)
                            set("index_refresh_days", sw.value)
                            if tmi and tmi.updateItems then tmi:updateItems() end
                        end,
                    })
                end,
            },

            {
                text_func = function()
                    return "Font size: " .. get("item_font_size")
                end,
                keep_menu_open = true,
                callback = function(tmi)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local UIManager  = require("ui/uimanager")
                    UIManager:show(SpinWidget:new{
                        title_text  = "Font size",
                        value       = get("item_font_size"),
                        value_min   = 10,
                        value_max   = 40,
                        value_step  = 1,
                        ok_text     = "Set",
                        callback    = function(sw)
                            set("item_font_size", sw.value)
                            if tmi and tmi.updateItems then tmi:updateItems() end
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return "Row height: " .. get("item_height")
                end,
                keep_menu_open = true,
                callback = function(tmi)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local UIManager  = require("ui/uimanager")
                    UIManager:show(SpinWidget:new{
                        title_text  = "Item row height (padding)",
                        value       = get("item_height"),
                        value_min   = 1,
                        value_max   = 10,
                        value_step  = 1,
                        ok_text     = "Set",
                        callback    = function(sw)
                            set("item_height", sw.value)
                            if tmi and tmi.updateItems then tmi:updateItems() end
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return "Button height: " .. get("bigger_buttons") .. "%"
                end,
                keep_menu_open = true,
                callback = function(tmi)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local UIManager  = require("ui/uimanager")
                    UIManager:show(SpinWidget:new{
                        title_text  = "Button height (%)",
                        value       = get("bigger_buttons"),
                        value_min   = 50,
                        value_max   = 300,
                        value_step  = 5,
                        ok_text     = "Set",
                        callback    = function(sw)
                            set("bigger_buttons", sw.value)
                            if tmi and tmi.updateItems then tmi:updateItems() end
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return "Button width: " .. get("bigger_buttons_width") .. "%"
                end,
                keep_menu_open = true,
                callback = function(tmi)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local UIManager  = require("ui/uimanager")
                    UIManager:show(SpinWidget:new{
                        title_text  = "Button width (%)",
                        value       = get("bigger_buttons_width"),
                        value_min   = 50,
                        value_max   = 300,
                        value_step  = 5,
                        ok_text     = "Set",
                        callback    = function(sw)
                            set("bigger_buttons_width", sw.value)
                            if tmi and tmi.updateItems then tmi:updateItems() end
                        end,
                    })
                end,
            },
            {
                text     = "Max rows per page",
                keep_menu_open = true,
                callback = function()
                    local SpinWidget = require("ui/widget/spinwidget")
                    local UIManager  = require("ui/uimanager")
                    UIManager:show(SpinWidget:new{
                        title_text = "Max rows per page",
                        value      = get("items_per_page"),
                        value_min  = 10,
                        value_max  = 25,
                        value_step = 1,
                        ok_text    = "Set",
                        callback   = function(sw) set("items_per_page", sw.value) end,
                    })
                end,
            },
                },
            })
        end
    end

    orig_setUpdateItemTable(self)
end

logger.info("[ftp-dl] plugin loaded")

return FTPDownloadManager
