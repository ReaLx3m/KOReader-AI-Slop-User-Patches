--[[
User patch: Show a semi-transparent vertical label on the left side
of each cover in mosaic view, rotated 90°.
Lines above cover are dynamic based on page count (configurable).

Label text options:
  • filename        – filename without extension (default)
  • title           – metadata title
  • author_title    – "Author – Title"
  • title_author    – "Title – Author"

Cover shape options (independent of spine label enabled state):
  • cover_scale_pct – scale cover up/down as % of its natural size (50–150)
  • aspect_enabled  – enforce a target aspect ratio on every cover
  • aspect_ratio_w/h – ratio W : H (e.g. 2, 3 → 2:3 portrait)
Settings exposed under: Settings → AI Slop Settings

Installation:
  Copy this file to:  koreader/patches/2-real-books.lua
--]]

-- ── defaults ──────────────────────────────────────────────────────────────────
local DEFAULTS = {
    enabled        = true,
    direction      = "up",
    text_mode      = "filename",
    alpha          = 0.80,
    font_size      = 16,
    font_bold      = true,
    font_face      = "NotoSerif",
    dark_mode      = true,
    text_shear     = 30,  -- stored as integer (0 to 100), divided by 100 at use
    padding        = 2,
    page_thickness = 2,
    page_spacing   = 1,
    lines_enabled_2 = true,
    lines_enabled_3 = true,
    lines_enabled_4 = true,
    lines_enabled_5 = true,
    lines_enabled_6 = true,
    lines_enabled_7 = false,
    lines_enabled_8 = false,
    lines_enabled_9 = false,
    lines_enabled_10 = false,
    page_range_2   = 100,
    page_range_3   = 200,
    page_range_4   = 350,
    page_range_5   = 500,
    page_range_6   = 700,
    page_range_7   = 900,
    page_range_8   = 1200,
    page_range_9   = 1500,
    epub_bytes_per_page = 2048,    -- ~2KB per page
    pdf_kb_per_page     = 100,     -- ~100KB per page
    cbz_kb_per_page     = 500,     -- ~500KB per page
    -- cover shape
    cover_scale_pct  = 95,         -- % of natural cover size (50–100)
    aspect_enabled   = false,      -- enforce target aspect ratio
    aspect_ratio_w   = 2,          -- ratio width part
    aspect_ratio_h   = 3,          -- ratio height part
    spine_width_pct       = 100,   -- spine width multiplier % (100–200)
    line_color            = "GRAY_9", -- page count line color (named palette key)
    page_line_length_pct  = 102,   -- page count lines length as % of cover width (10–150)
    progress_badge_enabled = true, -- show quarter-circle progress badge at bottom-right of cover
}

-- ── requires ──────────────────────────────────────────────────────────────────
local FileChooser      = require("ui/widget/filechooser")
local FileManagerMenu  = require("apps/filemanager/filemanagermenu")
local FileManagerMenuOrder = require("ui/elements/filemanager_menu_order")
local Blitbuffer       = require("ffi/blitbuffer")
local Font             = require("ui/font")
local TextWidget       = require("ui/widget/textwidget")
local CenterContainer  = require("ui/widget/container/centercontainer")
local Geom             = require("ui/geometry")
local userpatch        = require("userpatch")
local util             = require("util")
local logger           = require("logger")

if FileChooser._mosaic_vlabel_patched then return end
FileChooser._mosaic_vlabel_patched = true

-- ── DPI scale helper ──────────────────────────────────────────────────────────
-- Returns the ratio of device DPI to the 160 DPI reference baseline.
-- Font sizes divided by this value stay physically the same size across DPIs.
local function getDPIScale()
    local ok, Screen = pcall(require, "device/screen")
    if not ok or not Screen then return 1 end
    local dpi = Screen:getDPI()
    if not dpi or dpi <= 0 then return 1 end
    return dpi / 160
end

-- ── settings helpers ──────────────────────────────────────────────────────────
local function getCfg()
    return G_reader_settings:readSetting("mosaic_vlabel") or {}
end
local function get(key)
    local cfg = getCfg()
    if cfg[key] ~= nil then return cfg[key] end
    return DEFAULTS[key]
end
local function set(key, value)
    local cfg = getCfg()
    cfg[key] = value
    G_reader_settings:saveSetting("mosaic_vlabel", cfg)
    _item_cache = {}  -- any setting change invalidates the render cache
end

-- ── cached strip width (invalidated when font_size changes via menu) ──────────
local _strip_w_cache = nil
local _strip_w_key   = nil
local function getStripW(item_w)
    local fs  = get("font_size")
    local swp = get("spine_width_pct")
    local key = fs .. (item_w or 0) .. swp
    if _strip_w_cache and _strip_w_key == key then return _strip_w_cache end
    local pad = get("padding")
    local tw = TextWidget:new{ text = "A", face = Font:getFace("cfont", fs) }
    local font_h = tw:getSize().h
    tw:free()
    local max_w = math.floor((font_h + 2 * pad) * 0.75)
    if item_w and item_w > 0 then
        local scaled = math.floor(item_w * 0.15)
        _strip_w_cache = math.floor(math.min(max_w, scaled) * swp / 100)
    else
        _strip_w_cache = math.floor(max_w * swp / 100)
    end
    _strip_w_key = key
    return _strip_w_cache
end

-- ── module-level font map (constant, avoids rebuilding on every paintTo) ──────
local FONT_MAP = {
    NotoSerif            = { regular = "NotoSerif-Italic.ttf",                   bold = "NotoSerif-BoldItalic.ttf"          },
    NotoSerifRegular     = { regular = "NotoSerif-Regular.ttf",                  bold = "NotoSerif-Bold.ttf"                },
    NotoSans             = { regular = "NotoSans-Italic.ttf",                    bold = "NotoSans-BoldItalic.ttf"           },
    NotoSansRegular      = { regular = "NotoSans-Regular.ttf",                   bold = "NotoSans-Bold.ttf"                 },
    NotoNaskhArabic      = { regular = "NotoNaskhArabic-Regular.ttf",            bold = "NotoNaskhArabic-Bold.ttf"          },
    NotoSansArabicUI     = { regular = "NotoSansArabicUI-Regular.ttf",           bold = "NotoSansArabicUI-Bold.ttf"         },
    NotoSansBengaliUI    = { regular = "NotoSansBengaliUI-Regular.ttf",          bold = "NotoSansBengaliUI-Bold.ttf"        },
    NotoSansCJKsc        = { regular = "NotoSansCJKsc-Regular.otf",              bold = "NotoSansCJKsc-Regular.otf"         },
    NotoSansDevanagariUI = { regular = "NotoSansDevanagariUI-Regular.ttf",       bold = "NotoSansDevanagariUI-Bold.ttf"     },
    Symbols              = { regular = "symbols.ttf",                            bold = "symbols.ttf"                      },
    FreeSans             = { regular = "freefont/FreeSans.ttf",                  bold = "freefont/FreeSans.ttf"             },
    FreeSerif            = { regular = "freefont/FreeSerif.ttf",                 bold = "freefont/FreeSerif.ttf"            },
    DroidSansMono        = { regular = "droid/DroidSansMono.ttf",                bold = "droid/DroidSansMono.ttf"           },
}


-- ── page line color map ────────────────────────────────────────────────────────
local LINE_COLOR_MAP = {
    { key = "GRAY_1",      label = "Gray 1  (darkest)",  color = function() return Blitbuffer.COLOR_GRAY_1      end },
    { key = "GRAY_2",      label = "Gray 2",             color = function() return Blitbuffer.COLOR_GRAY_2      end },
    { key = "GRAY_3",      label = "Gray 3",             color = function() return Blitbuffer.COLOR_GRAY_3      end },
    { key = "GRAY_4",      label = "Gray 4  (default)",  color = function() return Blitbuffer.COLOR_GRAY_4      end },
    { key = "GRAY_5",      label = "Gray 5",             color = function() return Blitbuffer.COLOR_GRAY_5      end },
    { key = "GRAY_6",      label = "Gray 6",             color = function() return Blitbuffer.COLOR_GRAY_6      end },
    { key = "GRAY_7",      label = "Gray 7",             color = function() return Blitbuffer.COLOR_GRAY_7      end },
    { key = "DARK_GRAY",   label = "Dark gray",          color = function() return Blitbuffer.COLOR_DARK_GRAY   end },
    { key = "GRAY_9",      label = "Gray 9",             color = function() return Blitbuffer.COLOR_GRAY_9      end },
    { key = "GRAY",        label = "Gray  (mid)",        color = function() return Blitbuffer.COLOR_GRAY        end },
    { key = "LIGHT_GRAY",  label = "Light gray",         color = function() return Blitbuffer.COLOR_LIGHT_GRAY  end },
}
local function getLineColor()
    local key = get("line_color")
    for _, entry in ipairs(LINE_COLOR_MAP) do
        if entry.key == key then return entry.color() end
    end
    return Blitbuffer.COLOR_GRAY_4  -- fallback
end

-- ── BIM cover-dims cache (filepath → {cw, ch} in thumbnail pixels) ────────────
-- Avoids repeated SQLite queries for the same book within a session.
local _bim_dims_cache = {}

-- ── per-item render cache ──────────────────────────────────────────────────────
-- Key: filepath .. "|" .. item_w .. "x" .. item_h
-- Value: {left_off, top_off, cover_w, cover_h, name, num_lines}
-- Populated on first render of each item; cleared on folder navigation.
-- Makes select-mode repaints and menu-behind-grid repaints essentially free.
local _item_cache = {}

local function itemCacheKey(filepath, item_w, item_h)
    return (filepath or "") .. "|" .. item_w .. "x" .. item_h
end

-- Call this whenever settings change that affect geometry or text
local function invalidateItemCache()
    _item_cache = {}
    _bim_dims_cache = {}
end

-- ── BookInfoManager lazy grab ─────────────────────────────────────────────────
local _BookInfoManager
local function getBIM()
    if not _BookInfoManager then
        local ok, bim = pcall(require, "bookinfomanager")
        if ok and bim then
            _BookInfoManager = bim
        else
            local ok2, MosaicMenu = pcall(require, "mosaicmenu")
            if ok2 and MosaicMenu then
                local MM = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
                if MM and MM.update then
                    _BookInfoManager = userpatch.getUpValue(MM.update, "BookInfoManager")
                end
            end
        end
    end
    return _BookInfoManager
end

-- ── label text resolver ───────────────────────────────────────────────────────
local function getLabelText(self)
    local mode = get("text_mode")
    local raw  = self.filepath or self.text or ""

    if mode == "filename" then
        local _, filename = util.splitFilePathName(raw)
        return util.splitFileNameSuffix(filename)
    end

    local bim = getBIM()
    if bim then
        local ok, bookinfo = pcall(function()
            return bim:getBookInfo(raw, false)
        end)
        if ok and bookinfo then
            local title  = (bookinfo.title  and bookinfo.title  ~= "") and bookinfo.title  or nil
            local author = (bookinfo.authors and bookinfo.authors ~= "") and bookinfo.authors or nil
            if mode == "title" then
                return title or (function()
                    local _, fn = util.splitFilePathName(raw)
                    return util.splitFileNameSuffix(fn)
                end)()
            elseif mode == "author_title" then
                if author and title then return author .. " – " .. title
                elseif title        then return title
                elseif author       then return author end
            elseif mode == "title_author" then
                if title and author then return title .. " – " .. author
                elseif title        then return title
                elseif author       then return author end
            end
        end
    end

    local _, filename = util.splitFilePathName(raw)
    return util.splitFileNameSuffix(filename)
end

-- ── page count → line count ───────────────────────────────────────────────────
local _lines_cache = {}

-- ── reading-progress cache (filepath → {percent, is_finished}) ────────────────
local _progress_cache = {}

local function getPageCount(filepath)
    if not filepath then return nil end

    -- highest priority: explicit page count in filename e.g. "Book Title p234.epub"
    local fname = filepath:match("([^/]+)$") or ""
    local p = fname:match("[Pp](%d+)%.")
    if p then return tonumber(p) end

    local DocSettings = require("docsettings")
    local ok, docinfo = pcall(DocSettings.open, DocSettings, filepath)
    if ok and docinfo and docinfo.data then
        local pages = nil
        if docinfo.data.doc_pages and docinfo.data.doc_pages > 0 then
            pages = docinfo.data.doc_pages
        elseif docinfo.data.stats and docinfo.data.stats.pages and docinfo.data.stats.pages ~= 0 then
            pages = docinfo.data.stats.pages
        end
        docinfo:close()
        if pages then return pages end
    end

    local bim = getBIM()
    if bim then
        local ok2, bookinfo = pcall(function() return bim:getBookInfo(filepath, false) end)
        if ok2 and bookinfo then
            if bookinfo.nb_pages and bookinfo.nb_pages > 0 then return bookinfo.nb_pages end
        end
    end

    local ext = filepath:match("%.(%w+)$")
    if ext then ext = ext:lower() end
    local f = io.open(filepath, "rb")
    if f then
        local size = f:seek("end")
        f:close()
        if size and size > 0 then
            if ext == "epub" then
                return math.max(1, math.floor(size / get("epub_bytes_per_page"))), false
            elseif ext == "cbz" or ext == "cbr" then
                return math.max(1, math.floor(size / (get("cbz_kb_per_page") * 1024))), false
            elseif ext == "pdf" then
                return math.max(1, math.floor(size / (get("pdf_kb_per_page") * 1024))), false
            end
        end
    end

    return nil
end

local function getNumLines(filepath)
    if not filepath then return 2 end
    if _lines_cache[filepath] then return _lines_cache[filepath] end

    local pages = getPageCount(filepath)
    if not pages then return 4 end

    local max_lines = 10
    local ranges = {
        get("page_range_2"),
        get("page_range_3"),
        get("page_range_4"),
        get("page_range_5"),
        get("page_range_6"),
        get("page_range_7"),
        get("page_range_8"),
        get("page_range_9"),
    }

    local n = max_lines
    for i = 1, max_lines - 1 do
        local tier = i + 1
        if get("lines_enabled_" .. tier) == false then goto continue end
        if pages <= (ranges[i] or math.huge) then
            n = tier
            break
        end
        ::continue::
    end
    while n > 2 and get("lines_enabled_" .. n) == false do
        n = n - 1
    end

    _lines_cache[filepath] = n
    return n
end

-- ── reading-progress resolver ─────────────────────────────────────────────────
-- Returns (percent_int_or_nil, is_finished_bool).
-- percent is 0-100; nil means the book has never been opened / no recorded progress.
-- 0 means opened and percent_finished is present but rounds to 0.
local function getReadingProgress(filepath)
    if not filepath then return nil, false end
    if _progress_cache[filepath] then
        return _progress_cache[filepath].percent, _progress_cache[filepath].is_finished
    end

    local DocSettings = require("docsettings")
    local ok, docinfo = pcall(DocSettings.open, DocSettings, filepath)
    if not ok or not docinfo or not docinfo.data then
        _progress_cache[filepath] = { percent = nil, is_finished = false }
        return nil, false
    end

    -- finished status (set when user marks book complete)
    local is_finished = false
    if docinfo.data.summary and docinfo.data.summary.status then
        local s = docinfo.data.summary.status
        is_finished = (s == "complete" or s == "finished")
    end

    -- percentage (stored as 0.0-1.0 float by KOReader)
    -- Only set if percent_finished key actually exists — means book was genuinely opened
    local percent = nil
    local pf = docinfo.data.percent_finished
    if type(pf) == "number" then
        -- pf exists: book has been opened; clamp to 0-100
        percent = math.max(0, math.min(100, math.floor(pf * 100 + 0.5)))
    end

    if docinfo.close then pcall(function() docinfo:close() end) end

    _progress_cache[filepath] = { percent = percent, is_finished = is_finished }
    return percent, is_finished
end

-- ── progress badge painter ────────────────────────────────────────────────────
-- White filled rectangle with rounded top-left corner, anchored at the
-- bottom-right corner of the cover flush against the inside of the outline.
-- The outline's right/bottom bars and corner arc form the right/bottom border.
-- Black border on top and left edges only.
--
-- outline_r – same corner radius used by the outline arc.  We redraw the arc
--             on top of the fill so the corner is never overwritten.
local function paintProgressBadge(bb, cover_x, cover_y, cover_w, cover_h,
                                   percent, is_finished, ot, outline_r)
    -- nil percent means book never opened; show 0% so badge always covers the dog ear
    if percent == nil and not is_finished then percent = 0 end

    ot        = ot        or 2
    outline_r = outline_r or ot

    -- Badge dimensions: Ry controls height, Rx controls width
    local Ry = math.max(16, math.floor(math.min(cover_w, cover_h) * 0.143))
    local Rx = math.floor(Ry * 1.375)

    -- Inner corner flush against the inside face of the outline
    local ax = cover_x + cover_w - 1 - ot
    local ay = cover_y + cover_h - 1 - ot

    -- Badge extents
    local bx = ax - Rx + 1
    local bt = ay - Ry + 1

    -- Badge rounded top-left corner radius
    local rc       = math.max(4, math.floor(math.min(Rx, Ry) * 0.30))
    local rc_inner = math.max(0, rc - ot)

    -- Outline corner arc geometry (same as outline code):
    --   cx_arc = cover_x + cover_w - outline_r
    --   cy_arc = cover_y + cover_h - 1 - outline_r  (cy_br in outline)
    local cx_arc  = cover_x + cover_w - outline_r
    local cy_arc  = cover_y + cover_h - 1 - outline_r
    local r_inner = math.max(0, outline_r - ot)
    local right_edge = cover_x + cover_w - 1

    -- ── 1. White fill ────────────────────────────────────────────────────────
    -- Clip LEFT only at the badge's rounded top-left corner.
    -- Go all the way to ax on the right; step 2 redraws the arc ring on top.
    for py = bt, ay do
        local xl = bx

        local dy_corner = (bt + rc) - py
        if dy_corner > 0 then
            local chord = math.floor(
                math.sqrt(math.max(0, rc * rc - dy_corner * dy_corner)) + 0.5)
            xl = bx + rc - chord
        end

        if ax >= xl then
            bb:paintRect(xl, py, ax - xl + 1, 1, Blitbuffer.COLOR_WHITE)
        end
    end

    -- ── 2. Redraw the outline corner arc on top of the fill ──────────────────
    -- Step 1 painted white over the arc ring pixels in the badge area; restore
    -- them so the corner arc looks exactly as the outline code drew it.
    for dy = 1, outline_r do
        local row_br = cy_arc + dy
        if row_br > ay then break end
        local outer_dx = math.floor(
            math.sqrt(math.max(0, outline_r * outline_r - dy * dy)) + 0.5)
        outer_dx = math.min(outer_dx, right_edge - cx_arc)
        local inner_dx = r_inner > 0
            and math.floor(math.sqrt(math.max(0, r_inner * r_inner - dy * dy)) + 0.5)
            or 0
        local ring_len = (cx_arc + outer_dx) - (cx_arc + inner_dx) + 1
        if ring_len > 0 then
            bb:paintRect(cx_arc + inner_dx, row_br, ring_len, 1, Blitbuffer.COLOR_BLACK)
        end
    end

    -- ── 3. Black border on the two free edges ────────────────────────────────
    local arc_cx = bx + rc
    local arc_cy = bt + rc

    -- top bar (straight part after the rounded corner)
    local top_len = ax - arc_cx + 1
    if top_len > 0 then
        bb:paintRect(arc_cx, bt, top_len, ot, Blitbuffer.COLOR_BLACK)
    end
    -- left bar
    local left_len = ay - arc_cy + 1
    if left_len > 0 then
        bb:paintRect(bx, arc_cy, ot, left_len, Blitbuffer.COLOR_BLACK)
    end
    -- rounded top-left arc ring (upper-left quadrant, no erase needed)
    for dy = 0, rc do
        local outer_dx = math.floor(math.sqrt(math.max(0, rc * rc - dy * dy)) + 0.5)
        local inner_dx = rc_inner > 0
            and math.floor(math.sqrt(math.max(0, rc_inner * rc_inner - dy * dy)) + 0.5)
            or 0
        local ring_len = outer_dx - inner_dx
        local row = arc_cy - dy
        if ring_len > 0 and row >= bt then
            bb:paintRect(arc_cx - outer_dx, row, ring_len, 1, Blitbuffer.COLOR_BLACK)
        end
    end

    -- ── 4. Black text / checkmark ────────────────────────────────────────────
    local text_str = is_finished and "\xe2\x9c\x93" or (tostring(percent) .. "%")

    -- usable interior: left border (bx+ot) to right outline inside edge (ax-ot), top/bottom same
    local text_left  = bx + ot + 1
    local text_right = ax - ot
    local inner_w = text_right - text_left
    local inner_h = ay - (bt + ot) - ot

    -- start from a DPI-normalised size, then shrink until text fits the interior
    local badge_fs = math.max(6, math.floor(math.min(Rx, Ry) * 0.52 / getDPIScale()))
    local tw, ts
    for _ = 1, 10 do
        tw = TextWidget:new{
            text    = text_str,
            face    = Font:getFace("cfont", badge_fs),
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        ts = tw:getSize()
        if ts.w <= inner_w and ts.h <= inner_h then break end
        tw:free()
        badge_fs = math.max(6, badge_fs - 1)
    end

    -- center text within the explicit left/right bounds
    local usable_cx = math.floor((text_left + text_right) / 2)
    -- center text vertically, shifted ~15% down from true center
    local badge_h = ay - bt
    local badge_mid_y = math.floor(bt + badge_h * 0.58)
    local tx = math.max(text_left, usable_cx - math.floor(ts.w / 2))
    local ty = badge_mid_y - math.floor(ts.h / 2)
    tw:paintTo(bb, tx, ty)
    tw:free()
end

-- ── rounded-end line painter ──────────────────────────────────────────────────
local function paintRoundedLine(bb, x, y, len, thick, color)
    if len <= 0 or thick <= 0 then return end
    local r = math.floor(thick / 2)
    -- rectangular body between the two cap centres
    local body_x = x + r
    local body_len = len - 2 * r
    if body_len > 0 then
        bb:paintRect(body_x, y, body_len, thick, color)
    end
    -- filled-circle caps via scanline (avoids any external dependency)
    for dr = -r, r do
        local half_chord = math.floor(math.sqrt(math.max(0, r * r - dr * dr)) + 0.5)
        if half_chord > 0 then
            local cy = y + r + dr
            -- left cap
            bb:paintRect(x + r - half_chord, cy, half_chord, 1, color)
            -- right cap
            bb:paintRect(x + len - r, cy, half_chord, 1, color)
        end
    end
end

-- ── blitbuffer edge scan ──────────────────────────────────────────────────────
-- Only left_off and top_off are used by the caller; right/bottom are not needed.
local function findCoverEdges(bb, cell_x, cell_w, cell_y, cell_h)
    local left_offset = 0
    local top_offset  = 0

    local scan_rows = math.floor(cell_h * 0.25)
    for row = 0, scan_rows do
        local sy = cell_y + row
        for col = 0, cell_w - 1 do
            local c = bb:getPixel(cell_x + col, sy)
            if c and c:getR() < 250 then
                if col > left_offset then left_offset = col end
                break
            end
        end
    end

    local mid_x = cell_x + math.floor(cell_w / 2)
    for row = 0, cell_h - 1 do
        local c = bb:getPixel(mid_x, cell_y + row)
        if c and c:getR() < 250 then top_offset = row; break end
    end

    return left_offset, 0, top_offset, 0
end

-- ── cover shape transform ─────────────────────────────────────────────────────
-- Applies aspect-ratio enforcement and scale-% in a SINGLE scale operation.
-- When both are active the final pixel dimensions are computed first, then
-- one Blitbuffer scale() call produces the result directly — half the work
-- compared to doing the two steps sequentially.
local function applyCoverTransform(bb, x, y, item_w, item_h, cover_x, cover_y, cover_w, cover_h, left_reserve)
    left_reserve = left_reserve or 0
    local scale_pct   = get("cover_scale_pct")
    local asp_enabled = get("aspect_enabled")

    -- fast-path: nothing to do
    if scale_pct == 100 and not asp_enabled then
        return cover_x, cover_y, cover_w, cover_h
    end

    local cx, cy, cw, ch = cover_x, cover_y, cover_w, cover_h

    -- ── compute AR target box (geometry only, no pixels yet) ─────────────────
    local tgt_x, tgt_y, tgt_w, tgt_h
    if asp_enabled and cw > 0 and ch > 0 then
        local ratio_w = get("aspect_ratio_w")
        local ratio_h = get("aspect_ratio_h")

        local tgt_h_from_w = math.floor(item_w * ratio_h / ratio_w)
        if tgt_h_from_w <= item_h then
            tgt_w = item_w
            tgt_h = math.max(1, tgt_h_from_w)
        else
            tgt_h = item_h
            tgt_w = math.max(1, math.floor(item_h * ratio_w / ratio_h))
        end

        tgt_x = x + math.floor((item_w - tgt_w) / 2)
        tgt_y = y + math.floor((item_h - tgt_h) / 2)
    else
        -- no AR: treat the current cover box as the target
        tgt_x = cx
        tgt_y = cy
        tgt_w = cw
        tgt_h = ch
    end

    -- ── compute AR image dimensions (always stretch) ──────────────────────────
    local img_w = math.max(1, tgt_w)
    local img_h = math.max(1, tgt_h)

    -- ── apply scale% to the AR image dimensions ───────────────────────────────
    -- Compute the usable horizontal space accounting for spine reserve.
    -- The reserve is relative to the tgt box, not the full cell.
    local res_in_tgt = 0
    if scale_pct ~= 100 then
        res_in_tgt = math.max(0, (x + left_reserve) - tgt_x)
    end
    local usable_w = math.max(1, tgt_w - res_in_tgt)

    local final_w, final_h
    if scale_pct ~= 100 then
        final_w = math.max(1, math.floor(math.min(img_w, usable_w) * scale_pct / 100))
        final_h = math.max(1, math.floor(img_h * scale_pct / 100))
    else
        final_w = img_w
        final_h = img_h
    end

    -- ── compute final destination position ────────────────────────────────────
    local usable_x = tgt_x + res_in_tgt
    local dst_x, dst_y
    if scale_pct ~= 100 then
        dst_x = usable_x + math.floor((usable_w - final_w) / 2)
        dst_y = tgt_y    + math.floor((tgt_h    - final_h) / 2)
    else
        dst_x = tgt_x + math.floor((tgt_w - final_w) / 2)
        dst_y = tgt_y + math.floor((tgt_h - final_h) / 2)
    end

    -- ── early-out: no actual change ───────────────────────────────────────────
    if final_w == cw and final_h == ch and dst_x == cx and dst_y == cy then
        return cx, cy, cw, ch
    end

    -- ── single scale from original source to final dimensions ─────────────────
    local src = Blitbuffer.new(cw, ch, bb:getType())
    src:blitFrom(bb, 0, 0, cx, cy, cw, ch)
    local scaled = src:scale(final_w, final_h)
    src:free()

    bb:paintRect(x, y, item_w, item_h, Blitbuffer.COLOR_WHITE)

    local src_x, src_y = 0, 0
    local bw, bh = final_w, final_h

    if dst_x < x then
        src_x = x - dst_x; bw = bw - (x - dst_x); dst_x = x
    end
    if dst_y < y then
        src_y = y - dst_y; bh = bh - (y - dst_y); dst_y = y
    end
    bw = math.min(bw, x + item_w - dst_x)
    bh = math.min(bh, y + item_h - dst_y)
    bw = math.max(0, bw)
    bh = math.max(0, bh)

    if bw > 0 and bh > 0 then
        bb:blitFrom(scaled, dst_x, dst_y, src_x, src_y, bw, bh)
    end
    scaled:free()

    return dst_x, dst_y, bw, bh
end

-- ── core patch ────────────────────────────────────────────────────────────────
local function patchMosaicMenuItem(MosaicMenuItem)
    if MosaicMenuItem._vlabel_patched then return end
    MosaicMenuItem._vlabel_patched = true

    local orig_paintTo = MosaicMenuItem.paintTo

    MosaicMenuItem.paintTo = function(self, bb, x, y)
        orig_paintTo(self, bb, x, y)

        if self.is_directory then return end

        local item_w = self.dimen and self.dimen.w or self.width  or 0
        local item_h = self.dimen and self.dimen.h or self.height or 0
        if item_w == 0 or item_h == 0 then return end

        local filepath = self.filepath or self.text
        local ckey = itemCacheKey(filepath, item_w, item_h)
        local cached = _item_cache[ckey]

        local cover_x, cover_y, cover_w, cover_h, name, num_lines

        if cached then
            -- fast path: all geometry and text already known, skip all lookups
            cover_x   = x + cached.left_off
            cover_y   = y + cached.top_off
            cover_w   = cached.cover_w
            cover_h   = cached.cover_h
            name      = cached.name
            num_lines = cached.num_lines
        else
            -- slow path: compute everything and populate the cache

            -- detect cover position within cell
            local left_off, right_off, top_off, bottom_off = findCoverEdges(bb, x, item_w, y, item_h)
            cover_y = y + top_off
            cover_h = item_h - top_off - bottom_off
            cover_x = x + left_off
            cover_w = item_w - left_off - right_off

            -- BIM override using cached dims where possible
            do
                local bim_cw_raw, bim_ch_raw
                if _bim_dims_cache[filepath] then
                    bim_cw_raw = _bim_dims_cache[filepath].cw
                    bim_ch_raw = _bim_dims_cache[filepath].ch
                else
                    local bim = getBIM()
                    if bim and filepath then
                        local ok, bookinfo = pcall(function() return bim:getBookInfo(filepath, false) end)
                        if ok and bookinfo and bookinfo.cover_w and bookinfo.cover_h
                                and bookinfo.cover_w > 0 and bookinfo.cover_h > 0 then
                            bim_cw_raw = bookinfo.cover_w
                            bim_ch_raw = bookinfo.cover_h
                            _bim_dims_cache[filepath] = { cw = bim_cw_raw, ch = bim_ch_raw }
                        end
                    end
                end
                if bim_cw_raw and bim_ch_raw then
                    local scale = math.min(item_w / bim_cw_raw, item_h / bim_ch_raw)
                    local bim_cw = math.floor(bim_cw_raw * scale)
                    local bim_ch = math.floor(bim_ch_raw * scale)
                    if bim_cw > 4 and bim_ch > 4 then
                        cover_x = x + math.floor((item_w - bim_cw) / 2)
                        cover_y = y + math.floor((item_h - bim_ch) / 2)
                        cover_w = bim_cw
                        cover_h = bim_ch
                    end
                end
            end

            name      = getLabelText(self)
            num_lines = getNumLines(filepath)

            -- store offsets (not absolute coords) so cache is position-independent
            _item_cache[ckey] = {
                left_off  = cover_x - x,
                top_off   = cover_y - y,
                cover_w   = cover_w,
                cover_h   = cover_h,
                name      = name,
                num_lines = num_lines,
            }
        end

        -- ── cover shape: runs regardless of spine-label enabled state ─────────
        -- strip_w is computed early so applyCoverTransform can reserve that space
        -- on the left before sizing the cover — prevents right-edge clipping.
        local strip_w    = get("enabled") and getStripW(item_w) or 0
        local left_reserve = strip_w > 0 and (strip_w + 1) or 0
        if cover_w > 0 and cover_h > 0 then
            cover_x, cover_y, cover_w, cover_h = applyCoverTransform(
                bb, x, y, item_w, item_h, cover_x, cover_y, cover_w, cover_h, left_reserve)
        end

        -- ── replace KOReader's 1px outline with our own (page_thickness wide) ──
        -- Always runs: covers 100% scale, aspect ratio changes, and reduced scale.
        -- Left side intentionally omitted — the spine label sits there.
        -- cover_x/y/w/h boundary includes KOReader's 1px outline pixel, so we
        -- draw our outline overlapping inward from that boundary — no gap.
        if cover_w > 0 and cover_h > 0 then
            local ot = get("page_thickness")
            local r = math.min(ot * 4, math.floor(math.min(cover_w, cover_h) / 4))
            r = math.max(r, ot)
            local r_inner = r - ot  -- inner radius

            -- Pixel geometry (all inclusive):
            --   right_edge  = cover_x + cover_w - 1
            --   bottom_edge = cover_y + cover_h - 1
            --
            -- Arc centre x: cx = cover_x + cover_w - r
            --   → at dy=0: outer_dx = r, so rightmost pixel = cx + r - 1 = right_edge  ✓
            --
            -- Arc centre y for top-right:    cy_tr = cover_y + r
            --   → at dy=r: row = cy_tr - r = cover_y  ✓  (joins top bar)
            --   → right bar top  = cy_tr (first row below the arc's topmost point)
            --
            -- Arc centre y for bottom-right: cy_br = cover_y + cover_h - 1 - r
            --   → at dy=r: row = cy_br + r = cover_y + cover_h - 1 = bottom_edge  ✓
            --   → right bar bottom ends at cy_br (last row above arc's bottommost point)

            local cx    = cover_x + cover_w - r
            local cy_tr = cover_y + r
            local cy_br = cover_y + cover_h - 1 - r
            local right_edge  = cover_x + cover_w - 1
            local bottom_edge = cover_y + cover_h - 1

            -- Straight bars:
            -- top bar: cover_y .. cover_y+ot-1, from cover_x to cx-1
            bb:paintRect(cover_x, cover_y, cx - cover_x, ot, Blitbuffer.COLOR_BLACK)
            -- bottom bar: bottom_edge-ot+1 .. bottom_edge, from cover_x to cx-1
            bb:paintRect(cover_x, bottom_edge - ot + 1, cx - cover_x, ot, Blitbuffer.COLOR_BLACK)
            -- right bar: x = right_edge-ot+1 .. right_edge, from cy_tr to cy_br (inclusive)
            if cy_br >= cy_tr then
                bb:paintRect(right_edge - ot + 1, cy_tr, ot, cy_br - cy_tr + 1, Blitbuffer.COLOR_BLACK)
            end

            -- Rounded corners: for each dy 0..r, paint the arc ring row.
            -- dy=0 is the centre row (horizontal tangent), dy=r is the top/bottom tangent row.
            for dy = 0, r do
                local outer_dx = math.floor(math.sqrt(math.max(0, r * r - dy * dy)) + 0.5)
                local inner_dx = r_inner > 0
                    and math.floor(math.sqrt(math.max(0, r_inner * r_inner - dy * dy)) + 0.5)
                    or 0

                -- clamp outer so we never draw past right_edge
                outer_dx = math.min(outer_dx, right_edge - cx)

                local ring_start = cx + inner_dx
                local ring_end   = cx + outer_dx
                local ring_len   = ring_end - ring_start + 1

                -- erase the square corner region to the right of the arc
                local erase_start = ring_end + 1
                local erase_len   = right_edge - erase_start + 1

                -- top-right corner (rows from cy_tr upward to cover_y)
                local row_tr = cy_tr - dy
                if ring_len > 0 then
                    bb:paintRect(ring_start, row_tr, ring_len, 1, Blitbuffer.COLOR_BLACK)
                end
                if erase_len > 0 then
                    bb:paintRect(erase_start, row_tr, erase_len, 1, Blitbuffer.COLOR_WHITE)
                end

                -- bottom-right corner (rows from cy_br downward to bottom_edge)
                -- skip dy=0 to avoid repainting the shared centre row
                if dy > 0 then
                    local row_br = cy_br + dy
                    if ring_len > 0 then
                        bb:paintRect(ring_start, row_br, ring_len, 1, Blitbuffer.COLOR_BLACK)
                    end
                    if erase_len > 0 then
                        bb:paintRect(erase_start, row_br, erase_len, 1, Blitbuffer.COLOR_WHITE)
                    end
                end
            end
        end

        -- ── progress badge: rounded-rect corner label ────────────────────────
        -- Always paints when enabled, covering KOReader's dog ear.
        -- Unread books show 0%; finished books show ✓; others show percent.
        -- Native progress bar renders freely beneath — no suppression needed.
        if get("progress_badge_enabled") and cover_w > 0 and cover_h > 0 then
            local prog_pct, prog_done = getReadingProgress(filepath)
            local badge_ot = get("page_thickness")
            -- recompute outline corner radius (same formula as the outline block above)
            local badge_r = math.max(badge_ot,
                math.min(badge_ot * 4, math.floor(math.min(cover_w, cover_h) / 4)))
            paintProgressBadge(bb, cover_x, cover_y, cover_w, cover_h,
                               prog_pct, prog_done, badge_ot, badge_r)
        end

        -- ── spine label: gated by main enabled flag ───────────────────────────
        if not get("enabled") then return end
        if cover_w <= 0 or cover_h <= 0 then return end

        if not name or name == "" then return end

        -- strip_w already computed above; fetch remaining per-frame locals
        local pad   = get("padding")
        local fs    = get("font_size")
        local alpha = get("alpha")

        -- label sits flush against cover left edge; no overlap guaranteed by applyCoverTransform
        local label_x = math.max(x, cover_x - strip_w)

        -- angle cut depths (defined early so l_total can reference cut_h_top)
        local cut_h_bot = math.floor(strip_w * 0.5774)  -- tan(30°)

        -- dynamic line count based on page count
        local page_thick = get("page_thickness")
        local page_gap   = get("page_spacing")
        local line_step  = page_thick + page_gap
        local l_total    = num_lines * line_step
        local label_y    = cover_y - l_total
        local scale_pct  = get("cover_scale_pct")
        local label_h    = cover_h + l_total + (scale_pct < 100 and 1 or 0) - 1

        -- top angle always spans exactly l_total so right corner anchors to cover_y
        local cut_h_top  = l_total

        -- text max_width excludes the angled cut areas so text stays within visible box
        local text_max_w = label_h - cut_h_top - cut_h_bot - 2 * pad

        -- resolve font file from module-level map
        local face_entry = FONT_MAP[get("font_face")] or FONT_MAP["NotoSerif"]
        local font_file  = get("font_bold") and face_entry.bold or face_entry.regular

        -- build label widget sized to extended height
        local text_widget = TextWidget:new{
            text                  = name,
            face                  = Font:getFace(font_file, fs),
            fgcolor               = Blitbuffer.COLOR_WHITE,
            max_width             = math.max(1, text_max_w),
            truncate_with_ellipsis = false,
        }
        -- rotate and blit back with angled top/bottom ends
        local angle   = (get("direction") == "down") and 270 or 90

        -- sample the full cover strip (cover_h tall) then scale-stretch to label_h
        local tmp = Blitbuffer.new(label_h, strip_w, bb:getType())
        local src = Blitbuffer.new(strip_w, cover_h, bb:getType())
        src:blitFrom(bb, 0, 0, cover_x, cover_y, strip_w, cover_h)
        -- stretch src (strip_w × cover_h) → stretched (strip_w × label_h)
        local stretched = src:scale(strip_w, label_h)
        src:free()
        -- rotate cover 180° extra by using opposite angle then flip
        local img_angle = (angle == 90) and 270 or 90
        local src_rot = stretched:rotatedCopy(img_angle)
        stretched:free()
        tmp:blitFrom(src_rot, 0, 0, 0, 0, label_h, strip_w)
        src_rot:free()

        -- blend bg color at alpha opacity onto cover pixels
        local dark_mode = get("dark_mode")
        local bg_r, bg_g, bg_b = dark_mode and 0 or 255, dark_mode and 0 or 255, dark_mode and 0 or 255
        local blend_alpha = math.floor(alpha * 255)
        tmp:blendRectRGB32(0, 0, label_h, strip_w, Blitbuffer.ColorRGB32(bg_r, bg_g, bg_b, blend_alpha))

        -- paint text at 100% opacity on top
        local text_color = dark_mode and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        text_widget.fgcolor = text_color
        local text_only = CenterContainer:new{
            dimen = Geom:new{ w = label_h, h = strip_w },
            text_widget,
        }
        text_only:paintTo(tmp, 0, 0)
        text_only:free()
        local shear = -(get("text_shear") / 100)
        local sheared = Blitbuffer.new(label_h, strip_w, bb:getType())
        for row = 0, strip_w - 1 do
            local offset = math.floor((row - strip_w / 2) * shear)
            local src_x = math.max(0, -offset)
            local dst_x = math.max(0, offset)
            local w = label_h - math.abs(offset)
            if w > 0 then
                sheared:blitFrom(tmp, dst_x, row, src_x, row, w, 1)
            end
        end
        tmp:free()
        tmp = sheared

        local rotated = tmp:rotatedCopy(angle)
        tmp:free()

        -- save background strip before we draw (so we can restore corners)
        local bg = Blitbuffer.new(strip_w, label_h, bb:getType())
        bg:blitFrom(bb, 0, 0, label_x, label_y, strip_w, label_h)

        -- blit the full rotated rectangle
        bb:blitFrom(rotated, label_x, label_y, 0, 0, strip_w, label_h)
        rotated:free()

        for row = 0, math.max(cut_h_top, cut_h_bot) - 1 do
            local brow = label_h - (scale_pct < 100 and 0 or 1) - row
            if row < cut_h_top then
                local t = (cut_h_top - row) / cut_h_top
                local trim = math.floor(t ^ 0.6 * strip_w)
                if trim > 0 then
                    bb:blitFrom(bg, label_x + strip_w - trim, label_y + row, strip_w - trim, row, trim, 1)
                end
            end
            if row < cut_h_bot then
                local t = (cut_h_bot - row) / cut_h_bot
                local trim = math.floor((1 - (1 - t) ^ 0.6) * strip_w)
                if trim > 0 then
                    bb:paintRect(label_x, label_y + brow, trim, 1, Blitbuffer.COLOR_WHITE)
                end
            end
        end
        bg:free()

        -- draw lines above cover: all lines same length, anchored at spine angle edge
        do
            local color    = getLineColor()
            local len_pct  = get("page_line_length_pct")
            -- fixed line length based on cover width percentage
            local fixed_len = math.max(1, math.floor(cover_w * len_pct / 100))

            for i = 1, num_lines do
                local by = cover_y - page_thick - page_gap - (i - 1) * line_step
                -- compute where the spine angle ends for this row
                local row_in_cut = by - label_y
                local line_start
                if row_in_cut >= 0 and row_in_cut < cut_h_top then
                    local t = (cut_h_top - row_in_cut) / cut_h_top
                    local trim = math.floor(t ^ 0.6 * strip_w)
                    line_start = label_x + strip_w - trim
                else
                    line_start = label_x + strip_w
                end
                -- all lines same fixed length; topmost gets +1px so it visually caps the stack
                local this_len = (i == num_lines) and (fixed_len + 1) or fixed_len
                local draw_len = math.min(this_len, cover_x + cover_w - line_start)
                local line_color = (i == num_lines) and Blitbuffer.COLOR_GRAY_2 or color
                if draw_len > 0 then
                    paintRoundedLine(bb, line_start, by, draw_len, page_thick, line_color)
                end
            end
        end
    end
end

-- ── menu ──────────────────────────────────────────────────────────────────────
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
        if item._mosaic_vlabel_entry then already = true; break end
    end
    if not already then
        table.insert(self.menu_items.ai_slop_settings.sub_item_table, {
            _mosaic_vlabel_entry = true,
            text = "Real Books",
            sub_item_table_func = function()
                return {
                -- ── master toggle ──────────────────────────────────────────
                {
                    text_func = function()
                        return get("enabled") and "Spine label: enabled" or "Spine label: disabled"
                    end,
                    checked_func = function() return get("enabled") end,
                    callback = function(touchmenu_instance)
                        set("enabled", not get("enabled"))
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                        local fc = require("ui/widget/filechooser")
                        if fc.instance then fc.instance:updateItems() end
                    end,
                },
                -- ── progress badge toggle ───────────────────────────────────
                {
                    text_func = function()
                        return "Progress badge"
                    end,
                    checked_func = function() return get("progress_badge_enabled") end,
                    callback = function(touchmenu_instance)
                        set("progress_badge_enabled", not get("progress_badge_enabled"))
                        _progress_cache = {}
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                        local fc = require("ui/widget/filechooser")
                        if fc.instance then fc.instance:updateItems() end
                    end,
                },
                -- ── label text ─────────────────────────────────────────────
                {
                    text_func = function()
                        local v = get("spine_width_pct")
                        if v == 100 then return "Spine width: 100% (default)"
                        else return ("Spine width: %d%%"):format(v) end
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local SpinWidget = require("ui/widget/spinwidget")
                        local UIManager  = require("ui/uimanager")
                        UIManager:show(SpinWidget:new{
                            title_text          = "Spine width",
                            value               = get("spine_width_pct"),
                            value_min           = 100,
                            value_max           = 200,
                            value_step          = 5,
                            keep_shown_on_apply = true,
                            value_text_func     = function(v) return v .. "%" end,
                            callback = function(spin)
                                set("spine_width_pct", spin.value)
                                _strip_w_cache = nil
                                invalidateItemCache()
                                local fc = require("ui/widget/filechooser")
                                if fc.instance then fc.instance:updateItems() end
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        })
                    end,
                },
                {
                    text = "Label text",
                    sub_item_table = {
                        {
                            text = "Filename",
                            checked_func = function() return get("text_mode") == "filename" end,
                            callback = function()
                                set("text_mode", "filename")
                                local fc = require("ui/widget/filechooser")
                                if fc.instance then fc.instance:updateItems() end
                            end,
                        },
                        {
                            text = "Title",
                            checked_func = function() return get("text_mode") == "title" end,
                            callback = function()
                                set("text_mode", "title")
                                local fc = require("ui/widget/filechooser")
                                if fc.instance then fc.instance:updateItems() end
                            end,
                        },
                        {
                            text = "Author – Title",
                            checked_func = function() return get("text_mode") == "author_title" end,
                            callback = function()
                                set("text_mode", "author_title")
                                local fc = require("ui/widget/filechooser")
                                if fc.instance then fc.instance:updateItems() end
                            end,
                        },
                        {
                            text = "Title – Author",
                            checked_func = function() return get("text_mode") == "title_author" end,
                            callback = function()
                                set("text_mode", "title_author")
                                local fc = require("ui/widget/filechooser")
                                if fc.instance then fc.instance:updateItems() end
                            end,
                        },
                        {
                            text_func = function()
                                return get("direction") == "up" and "Text direction: Bottom to top" or "Text direction: Top to bottom"
                            end,
                            callback = function(touchmenu_instance)
                                set("direction", get("direction") == "up" and "down" or "up")
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                                local fc = require("ui/widget/filechooser")
                                if fc.instance then fc.instance:updateItems() end
                            end,
                        },
                        {
                            text_func = function()
                                return get("dark_mode") and "Text style: White on black" or "Text style: Black on white"
                            end,
                            callback = function(touchmenu_instance)
                                set("dark_mode", not get("dark_mode"))
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                                local fc = require("ui/widget/filechooser")
                                if fc.instance then fc.instance:updateItems() end
                            end,
                        },
                        {
                            text_func = function()
                                local v = get("alpha")
                                return ("Label opacity: %d%%"):format(math.floor(v * 100))
                            end,
                            keep_menu_open = true,
                            callback = function(touchmenu_instance)
                                local SpinWidget = require("ui/widget/spinwidget")
                                local UIManager  = require("ui/uimanager")
                                UIManager:show(SpinWidget:new{
                                    title_text          = "Label opacity",
                                    value               = math.floor(get("alpha") * 100),
                                    value_min           = 0,
                                    value_max           = 100,
                                    value_step          = 5,
                                    default_value       = math.floor(DEFAULTS.alpha * 100),
                                    keep_shown_on_apply = true,
                                    callback = function(spin)
                                        set("alpha", spin.value / 100)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                    end,
                                })
                            end,
                        },
                        {
                            text = "Font face",
                            sub_item_table = {
                                {
                                    text = "Noto Serif Italic",
                                    checked_func = function() return get("font_face") == "NotoSerif" and not get("font_bold") end,
                                    callback = function()
                                        set("font_face", "NotoSerif") set("font_bold", false)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Noto Serif Bold Italic",
                                    checked_func = function() return get("font_face") == "NotoSerif" and get("font_bold") end,
                                    callback = function()
                                        set("font_face", "NotoSerif") set("font_bold", true)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Noto Serif Regular",
                                    checked_func = function() return get("font_face") == "NotoSerifRegular" and not get("font_bold") end,
                                    callback = function()
                                        set("font_face", "NotoSerifRegular") set("font_bold", false)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Noto Serif Bold",
                                    checked_func = function() return get("font_face") == "NotoSerifRegular" and get("font_bold") end,
                                    callback = function()
                                        set("font_face", "NotoSerifRegular") set("font_bold", true)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Noto Sans Italic",
                                    checked_func = function() return get("font_face") == "NotoSans" and not get("font_bold") end,
                                    callback = function()
                                        set("font_face", "NotoSans") set("font_bold", false)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Noto Sans Bold Italic",
                                    checked_func = function() return get("font_face") == "NotoSans" and get("font_bold") end,
                                    callback = function()
                                        set("font_face", "NotoSans") set("font_bold", true)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Noto Sans Regular",
                                    checked_func = function() return get("font_face") == "NotoSansRegular" and not get("font_bold") end,
                                    callback = function()
                                        set("font_face", "NotoSansRegular") set("font_bold", false)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Noto Sans Bold",
                                    checked_func = function() return get("font_face") == "NotoSansRegular" and get("font_bold") end,
                                    callback = function()
                                        set("font_face", "NotoSansRegular") set("font_bold", true)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Free Serif",
                                    checked_func = function() return get("font_face") == "FreeSerif" end,
                                    callback = function()
                                        set("font_face", "FreeSerif")
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Free Sans",
                                    checked_func = function() return get("font_face") == "FreeSans" end,
                                    callback = function()
                                        set("font_face", "FreeSans")
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Droid Sans Mono",
                                    checked_func = function() return get("font_face") == "DroidSansMono" end,
                                    callback = function()
                                        set("font_face", "DroidSansMono")
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Noto Naskh Arabic Regular",
                                    checked_func = function() return get("font_face") == "NotoNaskhArabic" and not get("font_bold") end,
                                    callback = function()
                                        set("font_face", "NotoNaskhArabic") set("font_bold", false)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Noto Naskh Arabic Bold",
                                    checked_func = function() return get("font_face") == "NotoNaskhArabic" and get("font_bold") end,
                                    callback = function()
                                        set("font_face", "NotoNaskhArabic") set("font_bold", true)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Noto Sans Arabic UI Regular",
                                    checked_func = function() return get("font_face") == "NotoSansArabicUI" and not get("font_bold") end,
                                    callback = function()
                                        set("font_face", "NotoSansArabicUI") set("font_bold", false)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Noto Sans Arabic UI Bold",
                                    checked_func = function() return get("font_face") == "NotoSansArabicUI" and get("font_bold") end,
                                    callback = function()
                                        set("font_face", "NotoSansArabicUI") set("font_bold", true)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Noto Sans Bengali UI Regular",
                                    checked_func = function() return get("font_face") == "NotoSansBengaliUI" and not get("font_bold") end,
                                    callback = function()
                                        set("font_face", "NotoSansBengaliUI") set("font_bold", false)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Noto Sans Bengali UI Bold",
                                    checked_func = function() return get("font_face") == "NotoSansBengaliUI" and get("font_bold") end,
                                    callback = function()
                                        set("font_face", "NotoSansBengaliUI") set("font_bold", true)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Noto Sans CJK SC",
                                    checked_func = function() return get("font_face") == "NotoSansCJKsc" end,
                                    callback = function()
                                        set("font_face", "NotoSansCJKsc")
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Noto Sans Devanagari UI Regular",
                                    checked_func = function() return get("font_face") == "NotoSansDevanagariUI" and not get("font_bold") end,
                                    callback = function()
                                        set("font_face", "NotoSansDevanagariUI") set("font_bold", false)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Noto Sans Devanagari UI Bold",
                                    checked_func = function() return get("font_face") == "NotoSansDevanagariUI" and get("font_bold") end,
                                    callback = function()
                                        set("font_face", "NotoSansDevanagariUI") set("font_bold", true)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                                {
                                    text = "Symbols",
                                    checked_func = function() return get("font_face") == "Symbols" end,
                                    callback = function()
                                        set("font_face", "Symbols")
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                    end,
                                },
                            },
                        },
                        {
                            text_func = function()
                                return ("Font size: %d"):format(get("font_size"))
                            end,
                            keep_menu_open = true,
                            callback = function(touchmenu_instance)
                                local SpinWidget = require("ui/widget/spinwidget")
                                local UIManager  = require("ui/uimanager")
                                UIManager:show(SpinWidget:new{
                                    title_text          = "Font size",
                                    value               = get("font_size"),
                                    value_min           = 10,
                                    value_max           = 24,
                                    value_step          = 1,
                                    default_value       = DEFAULTS.font_size,
                                    keep_shown_on_apply = true,
                                    callback = function(spin)
                                        set("font_size", spin.value)
                                        _strip_w_cache = nil
                                        invalidateItemCache()
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                    end,
                                })
                            end,
                        },
                        {
                            text_func = function()
                                local v = get("text_shear")
                                if v == 0 then return "Text lean: none"
                                else return ("Text lean: %d%%"):format(v) end
                            end,
                            keep_menu_open = true,
                            callback = function(touchmenu_instance)
                                local SpinWidget = require("ui/widget/spinwidget")
                                local UIManager  = require("ui/uimanager")
                                UIManager:show(SpinWidget:new{
                                    title_text          = "Text lean",
                                    value               = get("text_shear"),
                                    value_min           = 0,
                                    value_max           = 100,
                                    value_step          = 5,
                                    default_value       = DEFAULTS.text_shear,
                                    keep_shown_on_apply = true,
                                    callback = function(spin)
                                        set("text_shear", spin.value)
                                        local fc = require("ui/widget/filechooser")
                                        if fc.instance then fc.instance:updateItems() end
                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                    end,
                                })
                            end,
                        },
                    },
                },
                -- ── cover shape ────────────────────────────────────────────
                {
                    text = "Cover shape",
                    sub_item_table_func = function()
                        local SpinWidget = require("ui/widget/spinwidget")
                        local UIManager  = require("ui/uimanager")
                        local function refresh(tmi)
                            invalidateItemCache()
                            local fc = require("ui/widget/filechooser")
                            if fc.instance then fc.instance:updateItems() end
                            if tmi then tmi:updateItems() end
                        end
                        return {
                            -- cover size %
                            {
                                text_func = function()
                                    local v = get("cover_scale_pct")
                                    if v == 100 then return "Cover size: 100% (natural)"
                                    else return ("Cover size: %d%%"):format(v) end
                                end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Cover size",
                                        value               = get("cover_scale_pct"),
                                        value_min           = 50,
                                        value_max           = 100,
                                        value_step          = 1,
                                        default_value       = DEFAULTS.cover_scale_pct,
                                        keep_shown_on_apply = true,
                                        value_text_func     = function(v) return v .. "%" end,
                                        callback = function(spin)
                                            set("cover_scale_pct", spin.value)
                                            refresh(tmi)
                                        end,
                                    })
                                end,
                            },
                            -- aspect ratio toggle
                            {
                                text_func = function()
                                    if get("aspect_enabled") then
                                        return ("Aspect ratio: %d:%d (enabled)"):format(
                                            get("aspect_ratio_w"), get("aspect_ratio_h"))
                                    else
                                        return "Aspect ratio: disabled"
                                    end
                                end,
                                checked_func = function() return get("aspect_enabled") end,
                                callback = function(tmi)
                                    set("aspect_enabled", not get("aspect_enabled"))
                                    refresh(tmi)
                                end,
                            },
                            -- ratio presets
                            {
                                text = "Ratio preset",
                                enabled_func = function() return get("aspect_enabled") end,
                                sub_item_table = {
                                    {
                                        text = "2:3  (standard book portrait)",
                                        checked_func = function()
                                            return get("aspect_ratio_w") == 2 and get("aspect_ratio_h") == 3
                                        end,
                                        callback = function()
                                            set("aspect_ratio_w", 2) set("aspect_ratio_h", 3)
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                        end,
                                    },
                                    {
                                        text = "3:4  (A4 / US Letter)",
                                        checked_func = function()
                                            return get("aspect_ratio_w") == 3 and get("aspect_ratio_h") == 4
                                        end,
                                        callback = function()
                                            set("aspect_ratio_w", 3) set("aspect_ratio_h", 4)
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                        end,
                                    },
                                    {
                                        text = "9:16  (tall)",
                                        checked_func = function()
                                            return get("aspect_ratio_w") == 9 and get("aspect_ratio_h") == 16
                                        end,
                                        callback = function()
                                            set("aspect_ratio_w", 9) set("aspect_ratio_h", 16)
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                        end,
                                    },
                                    {
                                        text = "1:1  (square)",
                                        checked_func = function()
                                            return get("aspect_ratio_w") == 1 and get("aspect_ratio_h") == 1
                                        end,
                                        callback = function()
                                            set("aspect_ratio_w", 1) set("aspect_ratio_h", 1)
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                        end,
                                    },
                                    {
                                        text = "3:2  (landscape)",
                                        checked_func = function()
                                            return get("aspect_ratio_w") == 3 and get("aspect_ratio_h") == 2
                                        end,
                                        callback = function()
                                            set("aspect_ratio_w", 3) set("aspect_ratio_h", 2)
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                        end,
                                    },
                                    -- custom W
                                    {
                                        text_func = function()
                                            return ("Custom ratio W: %d"):format(get("aspect_ratio_w"))
                                        end,
                                        keep_menu_open = true,
                                        callback = function(tmi)
                                            UIManager:show(SpinWidget:new{
                                                title_text          = "Ratio width",
                                                value               = get("aspect_ratio_w"),
                                                value_min           = 1,
                                                value_max           = 20,
                                                value_step          = 1,
                                                default_value       = DEFAULTS.aspect_ratio_w,
                                                keep_shown_on_apply = true,
                                                callback = function(spin)
                                                    set("aspect_ratio_w", spin.value)
                                                    local fc = require("ui/widget/filechooser")
                                                    if fc.instance then fc.instance:updateItems() end
                                                    if tmi then tmi:updateItems() end
                                                end,
                                            })
                                        end,
                                    },
                                    -- custom H
                                    {
                                        text_func = function()
                                            return ("Custom ratio H: %d"):format(get("aspect_ratio_h"))
                                        end,
                                        keep_menu_open = true,
                                        callback = function(tmi)
                                            UIManager:show(SpinWidget:new{
                                                title_text          = "Ratio height",
                                                value               = get("aspect_ratio_h"),
                                                value_min           = 1,
                                                value_max           = 20,
                                                value_step          = 1,
                                                default_value       = DEFAULTS.aspect_ratio_h,
                                                keep_shown_on_apply = true,
                                                callback = function(spin)
                                                    set("aspect_ratio_h", spin.value)
                                                    local fc = require("ui/widget/filechooser")
                                                    if fc.instance then fc.instance:updateItems() end
                                                    if tmi then tmi:updateItems() end
                                                end,
                                            })
                                        end,
                                    },
                                },
                            },
                        }
                    end,
                },
                -- ── page lines ─────────────────────────────────────────────
                {
                    text = "Page lines",
                    sub_item_table_func = function()
                        local SpinWidget = require("ui/widget/spinwidget")
                        local UIManager  = require("ui/uimanager")
                        local function refresh(tmi)
                            _lines_cache = {}
                            invalidateItemCache()
                            local fc = require("ui/widget/filechooser")
                            if fc.instance then fc.instance:updateItems() end
                            if tmi then tmi:updateItems() end
                        end
                        local items = {
                            {
                                text_func = function()
                                    return ("Line thickness: %d px"):format(get("page_thickness"))
                                end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Line thickness",
                                        value               = get("page_thickness"),
                                        value_min           = 1,
                                        value_max           = 5,
                                        value_step          = 1,
                                        default_value       = DEFAULTS.page_thickness,
                                        keep_shown_on_apply = true,
                                        callback = function(spin)
                                            set("page_thickness", spin.value)
                                            refresh(tmi)
                                        end,
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    return ("Line spacing: %d px"):format(get("page_spacing"))
                                end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Line spacing",
                                        value               = get("page_spacing"),
                                        value_min           = 0,
                                        value_max           = 5,
                                        value_step          = 1,
                                        default_value       = DEFAULTS.page_spacing,
                                        keep_shown_on_apply = true,
                                        callback = function(spin)
                                            set("page_spacing", spin.value)
                                            refresh(tmi)
                                        end,
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    local v = get("page_line_length_pct")
                                    return ("Line length: %d%% of cover width"):format(v)
                                end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Line length (% of cover width)",
                                        value               = get("page_line_length_pct"),
                                        value_min           = 10,
                                        value_max           = 150,
                                        value_step          = 5,
                                        default_value       = DEFAULTS.page_line_length_pct,
                                        keep_shown_on_apply = true,
                                        value_text_func     = function(v) return v .. "%" end,
                                        callback = function(spin)
                                            set("page_line_length_pct", spin.value)
                                            refresh(tmi)
                                        end,
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    local key = get("line_color")
                                    for _, entry in ipairs(LINE_COLOR_MAP) do
                                        if entry.key == key then
                                            return "Line color: " .. entry.label:gsub("%s+%b()",""):gsub("%s+$","")
                                        end
                                    end
                                    return "Line color: Gray 4"
                                end,
                                sub_item_table_func = function()
                                    local color_items = {}
                                    for _, entry in ipairs(LINE_COLOR_MAP) do
                                        local ekey = entry.key
                                        table.insert(color_items, {
                                            text = entry.label,
                                            checked_func = function() return get("line_color") == ekey end,
                                            callback = function()
                                                set("line_color", ekey)
                                                invalidateItemCache()
                                                local fc = require("ui/widget/filechooser")
                                                if fc.instance then fc.instance:updateItems() end
                                            end,
                                        })
                                    end
                                    return color_items
                                end,
                            },
                            {
                                text = "Show line tiers",
                                sub_item_table_func = function()
                                    local tier_items = {}
                                    for n = 2, 10 do
                                        local key = "lines_enabled_" .. n
                                        local nn = n
                                        table.insert(tier_items, {
                                            text = nn .. " lines",
                                            checked_func = function()
                                                return get(key) ~= false
                                            end,
                                            enabled_func = function()
                                                return nn ~= 2  -- 2 is always-on fallback
                                            end,
                                            callback = function()
                                                set(key, get(key) == false and true or false)
                                                _lines_cache = {}
                                                local fc = require("ui/widget/filechooser")
                                                if fc.instance then fc.instance:updateItems() end
                                            end,
                                        })
                                    end
                                    return tier_items
                                end,
                            },
                        }
                        local range_labels = { "2 lines", "3 lines", "4 lines", "5 lines", "6 lines", "7 lines", "8 lines", "9 lines" }
                        local range_keys   = { "page_range_2", "page_range_3", "page_range_4", "page_range_5", "page_range_6", "page_range_7", "page_range_8", "page_range_9" }
                        for tier = 1, 8 do
                            local key   = range_keys[tier]
                            local label = range_labels[tier]
                            local tier_enabled = get("lines_enabled_" .. (tier + 1)) ~= false
                            local is_highest = tier_enabled
                            for t = tier + 2, 10 do
                                if get("lines_enabled_" .. t) ~= false then
                                    is_highest = false
                                    break
                                end
                            end
                            if tier_enabled and not is_highest then
                                table.insert(items, {
                                    text_func = function()
                                        return ("%s: up to %d pages"):format(label, get(key))
                                    end,
                                    keep_menu_open = true,
                                    callback = function(tmi)
                                        UIManager:show(SpinWidget:new{
                                            title_text          = label .. ": upper page limit (pages)",
                                            value               = get(key),
                                            value_min           = 1,
                                            value_max           = 9999,
                                            value_step          = 10,
                                            default_value       = DEFAULTS[key],
                                            keep_shown_on_apply = true,
                                            callback = function(spin)
                                                set(key, spin.value)
                                                refresh(tmi)
                                            end,
                                        })
                                    end,
                                })
                            end
                        end
                        -- read-only display of the highest enabled tier
                        table.insert(items, {
                            text_func = function()
                                local highest = 2
                                for tier = 10, 2, -1 do
                                    if get("lines_enabled_" .. tier) ~= false then
                                        highest = tier
                                        break
                                    end
                                end
                                local last_threshold = 0
                                for tier = highest - 1, 2, -1 do
                                    if get("lines_enabled_" .. tier) ~= false then
                                        last_threshold = get(range_keys[tier - 1]) or 0
                                        break
                                    end
                                end
                                return ("%d lines: %d+ pages"):format(highest, last_threshold)
                            end,
                            enabled_func = function() return false end,
                            callback = function() end,
                        })
                        -- file size estimation settings
                        table.insert(items, {
                            text = "--- Pages estimation by filesize (fallback option) ---",
                            enabled_func = function() return false end,
                            callback = function() end,
                        })
                        local fmt_labels = { "EPUB bytes/page", "PDF KB/page", "CBZ KB/page" }
                        local fmt_keys   = { "epub_bytes_per_page", "pdf_kb_per_page", "cbz_kb_per_page" }
                        local fmt_is_kb  = { false, true, true }
                        for i = 1, 3 do
                            local key    = fmt_keys[i]
                            local label  = fmt_labels[i]
                            local is_kb  = fmt_is_kb[i]
                            table.insert(items, {
                                text_func = function()
                                    if is_kb then
                                        return ("%s: %d KB"):format(label, get(key))
                                    else
                                        return ("%s: %.1f KB"):format(label, get(key) / 1024)
                                    end
                                end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    UIManager:show(SpinWidget:new{
                                        title_text          = label,
                                        value               = is_kb and get(key) or math.floor(get(key) / 512),
                                        value_min           = 1,
                                        value_max           = 10000,
                                        value_step          = 1,
                                        default_value       = is_kb and DEFAULTS[key] or math.floor(DEFAULTS[key] / 512),
                                        keep_shown_on_apply = true,
                                        value_text_func     = is_kb and nil or function(v)
                                            return string.format("%.1f KB", v * 512 / 1024)
                                        end,
                                        callback = function(spin)
                                            set(key, is_kb and spin.value or spin.value * 512)
                                            _lines_cache = {}
                                            refresh(tmi)
                                        end,
                                    })
                                end,
                            })
                        end
                        return items
                    end,
                },
                }
            end,
        })
    end

    orig_setUpdateItemTable(self)
end

-- ── hook into genItemTableFromPath to grab MosaicMenuItem ────────────────────
local orig_genItemTableFromPath = FileChooser.genItemTableFromPath
function FileChooser:genItemTableFromPath(path, ...)
    _lines_cache = {}
    _item_cache  = {}
    _bim_dims_cache = {}
    _progress_cache = {}
    if not FileChooser._vlabel_done then
        local ok, MosaicMenu = pcall(require, "mosaicmenu")
        if ok and MosaicMenu then
            local MM = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
            if MM then
                patchMosaicMenuItem(MM)
                FileChooser._vlabel_done = true
            end
        end
    end
    return orig_genItemTableFromPath(self, path, ...)
end

logger.info("mlabel: patch applied")
