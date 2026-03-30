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

    Opportunistic TLS (AUTH TLS) is attempted automatically on connect.
    No companion patch required.
--]]

local logger = require("logger")
logger.info("[ftp-folder-dl] loading...")

-- ── Settings ──────────────────────────────────────────────────────────────────

local DEFAULTS = {
    enabled         = true,
    on_conflict     = "skip",      -- "skip" or "overwrite"
    natural_sort    = true,        -- sort 1,2,10 instead of 1,10,2
    items_per_page  = 10,          -- items shown per page in selection dialog (10-25)
    selection_shrink   = false,      -- shrink long names to fit (default: truncate)
    keep_structure    = false,      -- always mirror server folder structure
    prefer_ftps       = false,      -- try FTPS before plain FTP
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

-- ── Opportunistic TLS helpers ────────────────────────────────────────────────
-- On connect: plain TCP → FEAT → AUTH TLS if server supports it → SSL upgrade.
-- Falls back to plain FTP silently if TLS is unavailable or handshake fails.

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
    for _, name in ipairs({"default", "ssl", "libssl.so.3", "libssl.so.1.1", "libssl.so"}) do
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
        pcall(function() conn:close() end)
        _conn_pool[key] = nil
    end
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
    local function tcp_cmd(t, c) t:send(c .. "\r\n"); return tcp_recv_lines(t) end

    -- Attempt 1: plain FTP (or FTPS if prefer_ftps is set)
    local tcp, conn_err, plain_code
    local function plainConnect()
        local pt, pe = tcp_connect()
        if not pt then
            return nil, ("FTP connect %s:%d - %s"):format(host, port, tostring(pe))
        end
        tcp_recv_lines(pt)  -- welcome banner
        local pcode
        if user and user ~= "" then
            pcode = tcp_cmd(pt, "USER " .. user)
            if pcode == "331" then pcode = tcp_cmd(pt, "PASS " .. (pass or "")) end
        else
            tcp_cmd(pt, "USER anonymous"); pcode = tcp_cmd(pt, "PASS guest@")
        end
        if pcode ~= "230" then pt:close(); return nil, ("FTP login failed (%s)"):format(tostring(pcode)) end
        local c = { host=host, port=port, alive=true, tls=false, tcp=pt }
        function c:recv() return tcp_recv_lines(pt) end
        function c:cmd(s) pt:send(s .. "\r\n"); return self:recv() end
        function c:close()
            if not self.alive then return end
            self.alive = false
            pcall(function() self:cmd("QUIT") end)
            pcall(function() self.tcp:close() end)
        end
        c:cmd("TYPE I")
        return c
    end

    if get("prefer_ftps") then
        goto try_ftps
    end
    do
        local c, e = plainConnect()
        if c then return c end
        -- plain failed, fall through to FTPS
    end

    ::try_ftps::

    local ffi, lib = getTlsFfi()
    if not ffi or not lib then
        return nil, "FTP login failed and libssl unavailable for FTPS"
    end

    tcp, conn_err = tcp_connect()
    if not tcp then
        return nil, ("FTPS reconnect %s:%d - %s"):format(host, port, tostring(conn_err))
    end

    tcp_recv_lines(tcp)  -- welcome banner

    local auth_code = tcp_cmd(tcp, "AUTH TLS")
    if auth_code ~= "234" then
        tcp:close()
        -- AUTH TLS rejected - fall back to plain FTP
        return plainConnect()
    end

    local ctx = newTlsCtx(lib)
    if not ctx then tcp:close(); return nil, "FTPS: SSL_CTX_new failed" end

    local ctrl_ssl = lib.SSL_new(ctx)
    local ctrl_fd  = tcp:getfd()
    lib.SSL_set_fd(ctrl_ssl, ctrl_fd)
    setFdBlocking(ffi, ctrl_fd)
    local r = lib.SSL_connect(ctrl_ssl)
    if r ~= 1 then
        lib.SSL_free(ctrl_ssl); lib.SSL_CTX_free(ctx); tcp:close()
        -- TLS handshake failed - fall back to plain FTP
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
        local d = c .. "\r\n"
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
        code, line = conn:cmd("USER " .. user)
        if not code then conn:close(); return nil, "FTPS USER failed" end
        if code == "331" then
            code, line = conn:cmd("PASS " .. (pass or ""))
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
        local code = conn:cmd("NOOP")
        if not code then conn.alive = false; conn = nil end
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

    -- EPSV → PASV
    local data_host, data_port_num
    local code, line = conn:cmd("EPSV")
    if code == "229" then
        local ep = line:match("%(|[^|]*|[^|]*|(%d+)|%)")
        if ep then data_host = host; data_port_num = tonumber(ep) else code = nil end
    end
    if code ~= "229" then
        code, line = conn:cmd("PASV")
        if not code or code ~= "227" then
            return nil, "ctrl", "FTP PASV: " .. tostring(line)
        end
        local h1,h2,h3,h4,p1,p2 = line:match("(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)")
        if not h1 then return nil, "ctrl", "FTP PASV parse: " .. tostring(line) end
        data_host     = h1.."."..h2.."."..h3.."."..h4
        data_port_num = tonumber(p1)*256 + tonumber(p2)
    end

    -- Data TCP connect
    local dtcp = socket.tcp(); dtcp:settimeout(30)
    local dok, derr = dtcp:connect(data_host, data_port_num)
    if not dok then
        return nil, "data", ("FTP data connect — %s"):format(tostring(derr))
    end

    local read_data, close_data
    if conn.tls then
        local ffi, lib = conn.ffi, conn.lib
        local data_fd  = dtcp:getfd()
        local data_ssl = lib.SSL_new(conn.ctx)
        if data_ssl == nil then dtcp:close(); return nil, "data", "FTP: SSL_new (data) failed" end
        lib.SSL_set_fd(data_ssl, data_fd)
        setFdBlocking(ffi, data_fd)
        local ctrl_sess = lib.SSL_get1_session(conn.ctrl_ssl)
        if ctrl_sess ~= nil then
            lib.SSL_set_session(data_ssl, ctrl_sess)
            lib.SSL_SESSION_free(ctrl_sess)
        end
        local dr = lib.SSL_connect(data_ssl)
        if dr ~= 1 then
            local e = lib.SSL_get_error(data_ssl, dr)
            lib.SSL_shutdown(data_ssl); lib.SSL_free(data_ssl); dtcp:close()
            return nil, "data", ("FTP data TLS handshake failed (SSL err %d)"):format(e)
        end
        local rbuf = ffi.new("char[?]", 8192)
        read_data = function()
            local n = lib.SSL_read(data_ssl, rbuf, 8192)
            if n <= 0 then return nil end
            return ffi.string(rbuf, n)
        end
        close_data = function()
            lib.SSL_shutdown(data_ssl); lib.SSL_free(data_ssl); dtcp:close()
        end
    else
        read_data = function()
            local chunk, e, partial = dtcp:receive(8192)
            if chunk then return chunk end
            if partial and partial ~= "" then return partial end
            return nil
        end
        close_data = function() dtcp:close() end
    end

    -- FTP command
    local fcmd
    if not cmd_name then fcmd = "RETR " .. path
    elseif cmd_name:lower() == "mlsd" then fcmd = "MLSD " .. (path:match("/$") and path or path.."/")
    elseif cmd_name:lower() == "list" then fcmd = "LIST " .. (path:match("/$") and path or path.."/")
    elseif cmd_name:lower() == "nlst" then fcmd = "NLST " .. path
    else fcmd = cmd_name:upper() .. " " .. path end

    code, line = conn:cmd(fcmd)
    if not code or (code ~= "125" and code ~= "150") then
        close_data()
        return nil, "ctrl", ("FTP %s failed (%s): %s"):format(fcmd, tostring(code), tostring(line))
    end

    -- Stream data
    while true do
        local chunk = read_data()
        if not chunk then break end
        local sres, serr = sink(chunk)
        if not sres then
            close_data(); sink(nil)
            return nil, "data", "FTP sink: " .. tostring(serr)
        end
    end
    sink(nil)
    close_data()
    conn:recv()  -- 226 transfer complete

    return 1
end

-- ── Unified FTP get (pool + opportunistic TLS) ────────────────────────────────

local function connDoGet(p)
    local host = p.host
    local port = p.port or 21
    local user = p.user
    local pass = p.password

    local conn, cerr = getConn(host, port, user, pass)
    if not conn then return nil, cerr end

    local ok, r, chan, errmsg = pcall(doTransfer, conn, host, p.command, p.path or "/", p.sink)
    if not ok then
        conn.alive = false
        _conn_pool[connKey(host, port, user)] = nil
        return nil, tostring(r)
    end
    if not r then
        if chan == "ctrl" then
            conn.alive = false
            _conn_pool[connKey(host, port, user)] = nil
        end
        return nil, errmsg
    end
    return 1
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
    local ltn12 = require("ltn12")
    if not path:match("/$") then path = path .. "/" end
    local t = {}
    local p = baseParams(host, port, username, password)
    p.path    = path
    p.command = "mlsd"
    p.sink    = ltn12.sink.table(t)
    local ok, err = connDoGet(p)
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
    local ltn12 = require("ltn12")
    if not path:match("/$") then path = path .. "/" end
    local t = {}
    local p = baseParams(host, port, username, password)
    p.path    = path
    p.command = "list"
    p.sink    = ltn12.sink.table(t)
    local ok, err = connDoGet(p)
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
    local ltn12 = require("ltn12")
    if not path:match("/$") then path = path .. "/" end

    local t = {}
    local p = baseParams(host, port, username, password)
    p.path = path; p.command = "nlst"; p.sink = ltn12.sink.table(t)
    local ok, err = connDoGet(p)
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
    local ltn12 = require("ltn12")

    local f, err = io.open(local_path, "wb")
    if not f then
        return false, "cannot open local file: " .. tostring(err)
    end

    local p = baseParams(host, port, username, password)
    p.path = remote_path
    p.sink = ltn12.sink.file(f)  -- pipes chunks directly to disk, f closed by ltn12

    local ok, dl_err = connDoGet(p)
    if not ok then
        -- Clean up partial file on failure
        pcall(function() f:close() end)
        pcall(function() os.remove(local_path) end)
        return false, dl_err
    end
    return true
end

-- ── Recursive folder download ─────────────────────────────────────────────────

local function mkdirs(path)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") then return end
    local parent = path:match("^(.+)/[^/]+$")
    if parent and parent ~= "" then mkdirs(parent) end
    lfs.mkdir(path)
end

local function downloadFolder(host, port, username, password, remote_path, local_path, progress)
    local ok_count, fail_count = 0, 0

    mkdirs(local_path)

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
                ok_count = ok_count + 1
                if progress then progress(true, entry.name, nil) end
            else
                local ok_dl, dl_err = ftpGetFile(host, port, username, password,
                                                  r_child, l_child)
                if ok_dl then
                    ok_count = ok_count + 1
                    if progress then progress(true, entry.name, entry.size) end
                else
                    logger.warn("[ftp-folder-dl] GET failed:", r_child, dl_err)
                    fail_count = fail_count + 1
                    if progress then progress(false, entry.name, nil) end
                end
            end
        end
    end
    return ok_count, fail_count
end

-- ── CloudStorage patch ────────────────────────────────────────────────────────

-- ── Size formatting helper ────────────────────────────────────────────────────

local function fmtSize(bytes)
    if not bytes then return "" end
    if bytes < 1024 then return ("%dB"):format(bytes) end
    if bytes < 1024*1024 then return ("%dKB"):format(math.floor(bytes/1024 + 0.5)) end
    if bytes < 1024*1024*1024 then return ("%dMB"):format(math.floor(bytes/(1024*1024) + 0.5)) end
    return ("%.1fGB"):format(bytes/(1024*1024*1024))
end

local function fmtSizeRound(bytes)
    if not bytes then return "" end
    if bytes < 1024 then return ("%dB"):format(bytes) end
    if bytes < 1024*1024 then return ("%dKB"):format(math.floor(bytes/1024 + 0.5)) end
    if bytes < 1024*1024*1024 then return ("%dMB"):format(math.floor(bytes/(1024*1024) + 0.5)) end
    return ("%.1fGB"):format(bytes/(1024*1024*1024))
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
                                   base_dir,
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

    local conflict     = get("on_conflict")
    local conflict_lbl = conflict == "skip" and "[S]" or "[O]"
    -- base_dir: root download folder (prompted once per server, passed in)
    -- dl_dir is mutable: hold on Download button opens PathChooser to override.
    local _dest = { dir = base_dir or getDownloadDir() }
    local function dl_dir() return _dest.dir end
    -- local path for a remote path: mirrors server structure under base_dir
    local function localPath(remote_path)
        -- remote_path is absolute e.g. /Athena/Best/file.cbz
        -- result: base_dir/Athena/Best/file.cbz
        local rel = remote_path:gsub("^/", "")
        return dl_dir() .. (rel ~= "" and "/" .. rel or "")
    end
    local function local_dest() return localPath(cur_path) end

    -- Navigation stack for folder browsing.
    -- Each entry: { path, name, entries, page }
    local nav_stack   = {}
    local cur_path    = parent_remote_path
    local cur_name    = parent_local_name

    -- selections: flat map of full_remote_path -> bool, shared across all navigation levels
    local selections = {}
    -- helpers use cur_path which is now declared above
    local function entryPath(idx)
        return cur_path:gsub("/$","") .. "/" .. entries[idx].name
    end
    local function isChecked(idx)
        return selections[entryPath(idx)] ~= nil
    end
    -- Recursively count files and sum sizes in a folder path.
    local function countFolderContents(path)
        local es = ftpListEntries(host, port, username, password, path)
        if not es then return 0, 0 end
        local count, sz = 0, 0
        for _, e in ipairs(es) do
            if e.is_dir then
                local c, s = countFolderContents(path:gsub("/$","") .. "/" .. e.name)
                count = count + c; sz = sz + s
            else
                count = count + 1
                sz = sz + (e.size or 0)
            end
        end
        return count, sz
    end

    local function setChecked(idx, val)
        local path = entryPath(idx)
        if val then
            local e = entries[idx]
            local meta = { name=e.name, is_dir=e.is_dir, size=e.size }
            if e.is_dir then
                -- Show spinner and count recursively
                local UIManager2  = require("ui/uimanager")
                local InfoMessage2 = require("ui/widget/infomessage")
                local msg = InfoMessage2:new{ text = "Counting \"" .. e.name .. "\"…" }
                UIManager2:show(msg); UIManager2:forceRePaint()
                local count, sz = countFolderContents(path)
                UIManager2:close(msg)
                meta.size       = sz
                meta.file_count = count
            end
            selections[path] = meta
        else
            selections[path] = nil
        end
    end
    local function toggleChecked(idx)
        setChecked(idx, not isChecked(idx))
    end

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

    local size_col_w = Button:new{ text = "999MB", bordersize = 0,
                                   padding = 0, text_font_face = "cfont",
                                   text_font_size = 16 }:getSize().w
    local name_btn_w = row_w - size_col_w
    local text_pad   = Screen:scaleBySize(4)

    local slot_btns, size_btns = {}, {}
    local sep_widgets = {}  -- separator LineWidgets keyed by slot
    local count_btn        -- forward ref, assigned when title row is built
    local range_anchor = nil  -- global index of range-select anchor, nil = no anchor
    local updateTitle  -- forward ref; assigned after title_text_btn is created
    local turnPage     -- forward ref; defined after nav buttons are created

    local row_vg

    local function updateCount()
        if count_btn then
            local n, sz = 0, 0
            for _, meta in pairs(selections) do
                n = n + 1
                if meta.size then sz = sz + meta.size end
            end
            local sz_str = sz > 0 and "/" .. fmtSizeRound(sz) or ""
            count_btn:setText(">" .. n .. sz_str, count_btn.width)
            count_btn:refresh()
        end
    end

    local function checkPrefix(idx)
        if idx == range_anchor then
            return isChecked(idx) and "‹✓ " or "› "
        end
        return isChecked(idx) and "✓ " or ""
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
            local prefix   = entry and checkPrefix(idx) or ""
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
                hold_callback = function()
                    -- Long-press folder name: toggle selection
                    local real_idx = (page - 1) * per_page + slot
                    if not entries[real_idx] then return end
                    if range_anchor == real_idx then
                        range_anchor = nil
                        updateSlots(page)
                        return
                    end
                    toggleChecked(real_idx)
                    updateSlots(page)
                end,
                callback = function()
                    local real_idx = (page - 1) * per_page + slot
                    if not entries[real_idx] then return end
                    local e = entries[real_idx]
                    -- Tap folder name: navigate into it
                    if e.is_dir then
                        local sub_path = cur_path:gsub("/$","") .. "/" .. e.name
                        local msg = InfoMessage:new{ text = "Listing " .. e.name .. "…" }
                        UIManager:show(msg); UIManager:forceRePaint()
                        local sub_entries, err = ftpListEntries(host, port, username, password, sub_path)
                        UIManager:close(msg); UIManager:forceRePaint()
                        if not sub_entries then
                            UIManager:show(InfoMessage:new{
                                text = "Listing failed: " .. tostring(err), timeout = 4 })
                            return
                        end
                        table.sort(sub_entries, function(a, b)
                            if a.is_dir ~= b.is_dir then return a.is_dir end
                            if get("natural_sort") then return naturalLess(a.name, b.name) end
                            return a.name:lower() < b.name:lower()
                        end)
                        -- Push current state onto nav stack
                        table.insert(nav_stack, {
                            path    = cur_path,
                            name    = cur_name,
                            entries = entries,
                            page    = page,
                        })
                        -- Switch to subfolder
                        cur_path = sub_path
                        cur_name = e.name
                        entries  = sub_entries
                        range_anchor = nil
                        page_count = math.ceil(#entries / per_page)
                        turnPage(1)
                        if updateTitle then updateTitle() end
                        return
                    end
                    -- Cancel anchor if same item tapped again
                    if range_anchor == real_idx then
                        range_anchor = nil
                        updateSlots(page)
                        return
                    end
                    toggleChecked(real_idx)
                    if truncate then
                        -- in-place update: just flip the checkbox prefix
                        local px     = checkPrefix(real_idx)
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
                callback = function()
                    local real_idx = (page - 1) * per_page + slot
                    if not entries[real_idx] then return end
                    if range_anchor == nil then
                        -- Set anchor
                        range_anchor = real_idx
                        updateSlots(page)
                    elseif range_anchor == real_idx then
                        -- Tap same item again: cancel anchor, no state change
                        range_anchor = nil
                        updateSlots(page)
                    else
                        -- Apply range: check/uncheck all between anchor and here
                        local a, b = math.min(range_anchor, real_idx), math.max(range_anchor, real_idx)
                        local target = not isChecked(range_anchor)  -- opposite of anchor state
                        for i = a, b do setChecked(i, target) end
                        range_anchor = nil
                        updateSlots(page)
                    end
                end,
            }
            slot_btns[slot] = nbtn
            size_btns[slot] = sbtn
            table.insert(row_vg, HorizontalGroup:new{ align = "center", nbtn, sbtn })
            local sep = LineWidget:new{ dimen = Geom:new{ w = row_w, h = Screen:scaleBySize(1) } }
            sep_widgets[slot] = sep
            table.insert(row_vg, sep)
        end
        updateCount()
        if updateTitle then updateTitle() end
        UIManager:setDirty(dialog_widget, "ui")
    end

    row_vg = VerticalGroup:new{ allow_mirroring = false }
    updateSlots(page)

    -- Forward refs for nav widgets updated by turnPage
    local btn_prev, btn_next, btn_first, btn_last, page_label_btn, back_btn

    local function refreshNavButtons()
        if not btn_prev then return end
        if page > 1 then btn_prev:enable(); btn_first:enable()
        else btn_prev:disable(); btn_first:disable() end
        if page < page_count then btn_next:enable(); btn_last:enable()
        else btn_next:disable(); btn_last:disable() end
        local lbl = ("%d / %d"):format(page, page_count)
        page_label_btn:setText(lbl, page_label_btn.width)
        page_label_btn:refresh()
        btn_prev:refresh(); btn_next:refresh()
        btn_first:refresh(); btn_last:refresh()
        if back_btn then
            if #nav_stack > 0 then back_btn:enable() else back_btn:disable() end
            back_btn:refresh()
        end
    end

    turnPage = function(new_page)
        page  = new_page
        slots = math.min(per_page, #entries - (page - 1) * per_page)
        updateSlots(page)
        refreshNavButtons()
    end

    local function setPageChecked(state)
        local f = (page - 1) * per_page + 1
        local l = math.min(page * per_page, #entries)
        for i = f, l do setChecked(i, state) end
        updateSlots(page)
    end

    local function doDownload()
        -- Collect all selected items across all navigation levels
        local selected = {}
        for path, meta in pairs(selections) do
            table.insert(selected, {
                name   = meta.name,
                is_dir = meta.is_dir,
                size   = meta.size,
                url    = path,
            })
        end
        if #selected == 0 then
            UIManager:show(InfoMessage:new{ text = "Nothing selected.", timeout = 3 })
            return
        end

        local lfs = require("libs/libkoreader-lfs")
        local total_ok, total_fail, total_skip, total_dl = 0, 0, 0, 0
        -- Total file count is pre-computed at check time (folders counted recursively)
        local total_files = 0
        for _, meta in pairs(selections) do
            total_files = total_files + (meta.file_count or (meta.is_dir and 0 or 1))
        end
        local cur_msg

        cur_msg = InfoMessage:new{
            text = ('Downloading "%s"…'):format(parent_local_name),
        }
        UIManager:show(cur_msg)
        UIManager:forceRePaint()

        local function showProgress(filename, size)
            if cur_msg then UIManager:close(cur_msg) end
            cur_msg = InfoMessage:new{
                text = ("%d/%d downloaded%s, %d failed\n↓ %s %s"):format(
                    total_ok, total_files,
                    total_skip > 0 and (", %d skipped"):format(total_skip) or "",
                    total_fail, filename, fmtSize(size)),
            }
            UIManager:show(cur_msg)
            UIManager:forceRePaint()
        end

        local failed_urls = {}
        for _, entry in ipairs(selected) do
            local r_child = entry.url  -- already full remote path from selections
            -- For individual files: flat into base_dir unless keep_structure is on
            local l_child
            if get("keep_structure") then
                l_child = localPath(entry.url)
            else
                l_child = dl_dir() .. "/" .. entry.name
            end
            if entry.is_dir then
                local entry_fail = 0
                xpcall(
                    function()
                        downloadFolder(host, port, username, password,
                                       r_child, l_child,
                                       function(success, filename, size)
                                           if success and size then
                                               total_ok = total_ok + 1
                                               total_dl = total_dl + 1
                                           elseif success then
                                               total_skip = total_skip + 1
                                               total_ok   = total_ok   + 1
                                           else
                                               total_fail = total_fail + 1
                                               entry_fail = entry_fail + 1
                                           end
                                           showProgress(filename, size)
                                       end)
                    end,
                    function(e) logger.err("[ftp-folder-dl]", e); entry_fail = entry_fail + 1 end
                )
                if entry_fail > 0 then failed_urls[entry.url] = true end
            else
                -- Ensure parent directory exists
                local parent_dir = l_child:match("^(.+)/[^/]+$")
                if parent_dir then mkdirs(parent_dir) end
                local exists = lfs.attributes(l_child, "mode")
                if exists and get("on_conflict") == "skip" then
                    total_skip = total_skip + 1
                    total_ok   = total_ok   + 1
                    showProgress(entry.name, entry.size)
                else
                    showProgress(entry.name, entry.size)
                    local ok_dl = ftpGetFile(host, port, username, password, r_child, l_child)
                    if ok_dl then total_ok = total_ok + 1; total_dl = total_dl + 1
                    else total_fail = total_fail + 1; failed_urls[entry.url] = true end
                end
            end
        end

        if cur_msg then UIManager:close(cur_msg) end

        -- Uncheck successfully downloaded/skipped items; keep failed ones checked
        for _, entry in ipairs(selected) do
            if not failed_urls[entry.url] then
                selections[entry.url] = nil
            end
        end
        updateSlots(page)
        updateCount()
        UIManager:setDirty(dialog_widget, "ui")

        UIManager:show(InfoMessage:new{
            text = ("Done. %d saved%s, %d failed\n-> %s"):format(
                total_dl,
                total_skip > 0 and (", %d skipped"):format(total_skip) or "",
                total_fail, dl_dir()),
            timeout = 6,
        })
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
                            if n then turnPage(math.max(1, math.min(n, page_count))) end
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
                for i = 1, #entries do setChecked(i, true) end
                updateSlots(page)
            end,
        },
        HorizontalSpan:new{ width = Screen:scaleBySize(4) },
        Button:new{
            text          = "None", width = Screen:scaleBySize(70),
            callback      = function() setPageChecked(false) end,
            hold_callback = function()
                for i = 1, #entries do setChecked(i, false) end
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
            hold_callback = function()
                local PathChooser = require("ui/widget/pathchooser")
                local chooser = PathChooser:new{
                    select_directory = true,
                    select_file      = false,
                    show_files       = false,
                    path             = dl_dir(),
                    onConfirm        = function(dir)
                        _dest.dir = dir
                        UIManager:show(InfoMessage:new{
                            text = "Download folder set to:\n" .. dir,
                            timeout = 3,
                        })
                    end,
                }
                UIManager:show(chooser)
            end,
        },
        (function()
            local n, sz = 0, 0
            for _, meta in pairs(selections) do
                n = n + 1
                if meta.size then sz = sz + meta.size end
            end
            local sz_str = sz > 0 and "/" .. fmtSizeRound(sz) or ""
            local fixed_w = Screen:scaleBySize(70 + 4 + 70 + 10 + 4*44 + 4*2 + 90 + 10 + 140)
            local count_w = row_w - fixed_w
            -- Skip count button if there is not enough room (narrow screens).
            if count_w < Screen:scaleBySize(30) then
                return HorizontalSpan:new{ width = math.max(0, count_w) }
            end
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

    local function titleText()
        local back = #nav_stack > 0 and "<< " or ""
        if range_anchor then
            local anchor_name = entries[range_anchor] and entries[range_anchor].name or ""
            local anchor_mark = isChecked(range_anchor) and "‹" or "›"
            return ('%s"%s"  %s  %s%d: %s'):format(
                back, cur_name, conflict_lbl, anchor_mark, range_anchor, anchor_name)
        end
        return ('%s"%s"  %s'):format(back, cur_name, conflict_lbl)
    end
    local title_text_btn = Button:new{
        text      = titleText(),
        align     = "left",
        face      = small_face,
        width     = dialog_w - padding * 2 - Screen:scaleBySize(48),
        bordersize = 0,
        padding   = 0,
        callback  = function()
            if #nav_stack == 0 then return end
            local prev = table.remove(nav_stack)
            cur_path   = prev.path
            cur_name   = prev.name
            entries    = prev.entries
            page_count = math.ceil(#entries / per_page)
            range_anchor = nil
            turnPage(math.min(prev.page, page_count))
            if updateTitle then updateTitle() end
        end,
    }
    updateTitle = function()
        title_text_btn:setText(titleText(), title_text_btn.width)
        title_text_btn:refresh()
    end
    local title_row = OverlapGroup:new{
        dimen = Geom:new{ w = dialog_w - padding * 2, h = title_h },
        title_text_btn,
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
                    pcall(closePool)
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

    dialog_widget = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius     = Screen:scaleBySize(5),
        padding    = 0,
        width      = dialog_w,
        [1]        = inner,
    }

    UIManager:show(dialog_widget)
end

-- ── CloudStorage: open FTP server → show selection dialog directly ──────────

local ok, CloudStorage = pcall(require, "apps/cloudstorage/cloudstorage")
if not ok or not CloudStorage then
    logger.warn("[ftp-folder-dl] CloudStorage not found:", CloudStorage)
    return
end

local orig_openCloudServer = CloudStorage.openCloudServer
function CloudStorage:openCloudServer(url)
    if self.type ~= "ftp" then
        return orig_openCloudServer(self, url)
    end
    if not get("enabled") then
        return orig_openCloudServer(self, url)
    end

    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        NetworkMgr:beforeWifiAction(function()
            self:openCloudServer(url)
        end)
        return
    end

    local host, port  = parseAddress(self.address or "")
    local username    = self.username or ""
    local password    = self.password or ""
    local server_name = host
    if type(self.item_table) == "table" then
        local function stripScheme(s)
            return (s or ""):gsub("^ftps?://", "")
        end
        local bare_self = stripScheme(self.address)
        for _, item in ipairs(self.item_table) do
            if stripScheme(item.address) == bare_self and type(item.text) == "string" then
                server_name = item.text
                break
            end
        end
    end

    -- Per-server base download dir, prompted on first use
    local cfg_key = "ftp_base_dir_" .. host
    local saved_dir = G_reader_settings:readSetting(cfg_key)

    if not saved_dir or saved_dir == "" then
        local PathChooser = require("ui/widget/pathchooser")
        local UIManager2  = require("ui/uimanager")
        local InfoMessage2 = require("ui/widget/infomessage")
        UIManager2:show(InfoMessage2:new{
            text = "Choose a base download folder for \"" .. server_name .. "\"\nThis will be remembered.",
            timeout = 3,
        })
        UIManager2:forceRePaint()
        local chooser = PathChooser:new{
            select_directory = true,
            select_file      = false,
            show_files       = false,
            path             = getDownloadDir(),
            onConfirm        = function(dir)
                G_reader_settings:saveSetting(cfg_key, dir)
                showSelectionDialog(host, port, username, password, "/", server_name, dir)
            end,
        }
        UIManager2:show(chooser)
    else
        showSelectionDialog(host, port, username, password, "/", server_name, saved_dir)
    end
end

-- ── AI Slop Settings menu ─────────────────────────────────────────────────────
-- The submenu item table is exposed via package.loaded so companion patches
-- can insert their own entries at load time before the menu is ever built.

local _ftp_menu_items = {
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
        text = "Prioritize FTPS",
        checked_func = function() return get("prefer_ftps") end,
        callback = function() set("prefer_ftps", not get("prefer_ftps")) end,
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
        text = "Natural sorting (1, 2, 10)",
        checked_func = function() return get("natural_sort") end,
        callback = function() set("natural_sort", not get("natural_sort")) end,
    },
    {
        text = "Shrink long names to fit",
        checked_func = function() return get("selection_shrink") end,
        callback = function() set("selection_shrink", not get("selection_shrink")) end,
    },
    {
        text = "Always keep folder structure",
        checked_func = function() return get("keep_structure") end,
        callback = function() set("keep_structure", not get("keep_structure")) end,
    },
    {
        text = "Items per page",
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
}
-- Expose so companion patches (loaded after us) can insert entries before the
-- menu is built. Any item inserted into this table at load time will appear
-- automatically when the FileManager opens.
package.loaded["ftp-folder-dl.submenu"] = _ftp_menu_items

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
            sub_item_table = _ftp_menu_items,
        })
    end

    orig_setUpdateItemTable(self)
end

logger.info("[ftp-folder-dl] patch applied")
