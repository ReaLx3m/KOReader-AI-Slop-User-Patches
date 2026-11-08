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

Progress dot shape options (Settings → AI Slop Settings → Progress dots → Shape):
  • rounded_square   – square with rounded corners (corner_pct controls radius; rect_aspect% controls height)
  • diamond          – rotated square / rhombus
  • pill             – capsule / stadium shape (rect_aspect% controls height)

Ball sizing: fully automatic — ball radius grows to fill the space left by the margins:
  • margin_pct     – gap from ball edge to cover outline, as % of the perpendicular cover dimension
  • end_margin_pct – clearance at each end of the ball row/column, as % of the layout cover dimension
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
    spine_width_pct       = 150,   -- spine width as ‰ of cover_w (stored ×10; 150 = 15.0%)
    spine_width_max_px    = 0,     -- hard cap on spine width in pixels (0 = disabled)
    line_color            = "GRAY_9", -- page count line color (named palette key)
    page_line_length_pct  = 102,   -- page count lines length as % of cover width (10–150)
    progress_badge_enabled        = true,           -- show progress badge on cover
    progress_badge_alpha          = 0.80,           -- badge background opacity (0.0–1.0)
    progress_badge_show_percent   = true,           -- show % progress text in badge
    progress_badge_show_checkmark = true,           -- show checkmark for finished books
    progress_badge_position       = "bottom_right", -- corner: "bottom_right", "top_right"
    progress_badge_bg_color       = "BLACK",         -- badge background color key (same palette as ball fill color)
    progress_badge_check_color    = "WHITE",         -- checkmark / % text color: "WHITE" or "BLACK"
    progress_badge_shape          = "rectangle",    -- badge shape: "rectangle" (default) or "pentagon" (upside-down house, top-right only)
    pentagon_badge_w_pct          = 220,            -- pentagon badge width  as ‰ of cover_w (stored ×10; 220 = 22.0%)
    pentagon_badge_h_pct          = 270,            -- pentagon badge height as ‰ of min(cover_w,cover_h) (stored ×10; 270 = 27.0%)
    pentagon_badge_rect_pct       = 750,            -- rectangular portion as ‰ of total height (stored ×10; 750 = 75.0%)
    pentagon_badge_right_margin_pct = 100,          -- gap from badge right edge to cover right outline, as ‰ of cover_w (stored ×10; 100 = 10.0%)
    pentagon_badge_fill_mode        = false,         -- Pentagon/W badge: fill badge top-to-bottom with progress instead of showing %
    pentagon_badge_fill_color       = "WHITE",       -- fill mode overlay color (same palette as ball fill color)
    progress_dots_enabled  = true, -- show fill-dots at bottom of cover indicating progress
    progress_dots_num_dots = 7,    -- number of balls (dots) in the row (1–40)
    progress_dots_sections = 2,    -- fill subdivisions per ball (1–100); total steps = num_dots * sections
    progress_dots_outline    = 1,    -- ball outline thickness in px (0 = no outline)
    progress_dots_gap_pct    = 100,  -- gap between balls as % of ball radius (e.g. 100 = 1× radius)
    progress_dots_margin_pct = 30,   -- gap between ball edge and cover outline as ‰ of cover dimension (stored ×10; 30 = 3.0%)
    progress_dots_end_margin_pct = 50, -- clearance kept clear at each end of the ball row/column as ‰ of cover dimension (stored ×10; 50 = 5.0%)
    progress_dots_alpha    = 1.0,  -- ball opacity (0.0 = fully transparent, 1.0 = fully opaque)
    progress_dots_position = "bottom", -- ball row position: "bottom", "top", "left", "right"
    progress_dots_appear_mode = false, -- when true: balls appear one-by-one as you read, fully filled with fill color
    progress_dots_shape       = "rounded_square", -- shape of each dot: "rounded_square",
                                          -- "diamond", "pill"
    progress_dots_rect_aspect = 50,   -- height of pill as % of full diameter (1–100); 100 = square
    progress_dots_corner_pct  = 35,   -- corner radius for rounded_square as % of r (5–50)
    progress_dots_hide_on_finished = false, -- when true: hide progress bar dots for books marked as finished
    progress_dots_fill_color  = "BLACK",    -- fill color key: "BLACK", "GRAY_1" … "GRAY_9", "WHITE"
    spine_series_prefix       = false,      -- prepend "N# " series info to spine label when metadata present
    -- cover fill
    cover_fill_enabled        = false,      -- fill cover with progress overlay
    cover_fill_alpha          = 0.50,       -- fill overlay opacity (0.0–1.0)
    cover_fill_color          = "WHITE",    -- fill overlay color key (same palette as ball fill color)
    cover_fill_top_to_bottom  = false,      -- fill direction: false = bottom-to-top (default), true = top-to-bottom
    cover_fill_hide_on_finished = false,    -- hide fill overlay on books marked as finished
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
local DocSettings      = require("docsettings")

if FileChooser._mosaic_vlabel_patched then return end
FileChooser._mosaic_vlabel_patched = true

-- ── DPI scale helper ──────────────────────────────────────────────────────────
-- Returns the ratio of device DPI to the 160 DPI reference baseline.
-- Font sizes divided by this value stay physically the same size across DPIs.
-- Result is cached at module level: DPI never changes at runtime.
local _dpi_scale = nil
local function getDPIScale()
    if _dpi_scale then return _dpi_scale end
    local ok, Screen = pcall(require, "device/screen")
    if not ok or not Screen then _dpi_scale = 1; return 1 end
    local dpi = Screen:getDPI()
    _dpi_scale = (dpi and dpi > 0) and (dpi / 160) or 1
    return _dpi_scale
end

-- ── settings helpers ──────────────────────────────────────────────────────────
-- _cfg_cache holds the settings table in memory so that get() never calls
-- G_reader_settings:readSetting() more than once between two set() calls.
-- set() writes through and then nils the cache so the next get() re-reads.
-- _line_color_cache holds the resolved Blitbuffer color object for the current
-- line_color setting; invalidated alongside _cfg_cache on every set().
local _cfg_cache = nil
local _line_color_cache = nil
local function getCfg()
    if not _cfg_cache then
        _cfg_cache = G_reader_settings:readSetting("mosaic_vlabel") or {}
    end
    return _cfg_cache
end
local function get(key)
    local cfg = getCfg()
    if cfg[key] ~= nil then return cfg[key] end
    return DEFAULTS[key]
end
-- Clears both render-geometry caches together.  Called by set() and by
-- genItemTableFromPath so the two caches are always invalidated as a unit.
-- _item_cache and _bim_dims_cache are declared further down in the file but
-- Lua resolves upvalues at call time, not definition time, so this is safe.
local function invalidateItemCache()
    if _spine_render_cache then
        for _, by_dim in pairs(_spine_render_cache) do
            for _, cached in pairs(by_dim) do
                if cached and cached.rotated and cached.rotated.free then
                    cached.rotated:free()
                end
            end
        end
    end
    if _badge_render_cache then
        for _, cached in pairs(_badge_render_cache) do
            if cached and cached.buf and cached.buf.free then
                cached.buf:free()
            end
        end
    end
    if _spine_bg_scratch and _spine_bg_scratch.buf and _spine_bg_scratch.buf.free then
        _spine_bg_scratch.buf:free()
    end
    _item_cache = {}
    _bim_dims_cache = {}
    _spine_render_cache = {}
    _badge_render_cache = {}
    _filesize_pages_cache = {}
    _spine_bg_scratch = nil
    _page_line_layout_cache = {}
    _arc_cache = {}             -- arc tables are cheap to recompute; clear to bound memory
end
local function set(key, value)
    local cfg = getCfg()
    cfg[key] = value
    G_reader_settings:saveSetting("mosaic_vlabel", cfg)
    _cfg_cache = nil        -- invalidate so next get() re-reads
    _line_color_cache = nil -- invalidate resolved color (depends on line_color setting)
    _dots_fill_color_cache  = nil -- invalidate dots fill color cache
    _badge_bg_color_cache   = nil -- invalidate badge background color cache
    _badge_check_color_cache = nil -- invalidate badge check/text color cache
    _badge_fill_color_cache = nil -- invalidate badge fill color cache
    _cover_fill_color_cache = nil -- invalidate cover fill color cache
    _strip_w_cache   = nil  -- invalidate strip-width numeric cache
    _strip_w_cover_w = nil
    _strip_w_swp     = nil
    _strip_w_maxpx   = nil
    _ranges_cache        = nil  -- invalidate page-range threshold cache
    _lines_enabled_cache = nil  -- invalidate tier-enabled flags cache
    invalidateItemCache()   -- clears _item_cache and _bim_dims_cache together
end

-- ── cached strip width (derived from cover_w, same pattern as badges) ─────────
-- spine_width_pct is stored as ‰ of cover_w (×10); e.g. 150 = 15.0%.
-- spine_width_max_px is included in the cache key: a change to only max_px
-- (with swp and cover_w unchanged) would otherwise not invalidate the cache.
local _strip_w_cache    = nil
local _strip_w_cover_w  = nil   -- numeric cache keys — no string allocation
local _strip_w_swp      = nil
local _strip_w_maxpx    = nil
local function getStripW(cover_w)
    local swp    = get("spine_width_pct")
    local max_px = get("spine_width_max_px")
    if _strip_w_cache and _strip_w_cover_w == cover_w and _strip_w_swp == swp
            and _strip_w_maxpx == max_px then
        return _strip_w_cache
    end
    local w = math.max(8, math.floor((cover_w or 0) * swp / 1000))
    if max_px and max_px > 0 then w = math.min(w, max_px) end
    _strip_w_cache   = w
    _strip_w_cover_w = cover_w
    _strip_w_swp     = swp
    _strip_w_maxpx   = max_px
    return _strip_w_cache
end

-- ── font face cache ───────────────────────────────────────────────────────────
local _face_cache = {}
local function getFaceCached(font_file, size)
    local by_file = _face_cache[font_file]
    if not by_file then
        by_file = {}
        _face_cache[font_file] = by_file
    end
    local face = by_file[size]
    if not face then
        face = Font:getFace(font_file, size)
        by_file[size] = face
    end
    return face
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
-- Hash map for O(1) key → color function lookup (replaces linear ipairs scan)
local LINE_COLOR_LOOKUP = {}
for _, entry in ipairs(LINE_COLOR_MAP) do
    LINE_COLOR_LOOKUP[entry.key] = entry.color
end

local function getLineColor()
    if _line_color_cache then return _line_color_cache end
    local key = get("line_color")
    local fn = LINE_COLOR_LOOKUP[key]
    _line_color_cache = fn and fn() or Blitbuffer.COLOR_GRAY_4  -- fallback
    return _line_color_cache
end

-- ── progress dots fill color map ──────────────────────────────────────────────
local DOTS_FILL_COLOR_MAP = {
    { key = "BLACK",     label = "Black  (default)",   color = function() return Blitbuffer.COLOR_BLACK     end },
    { key = "GRAY_1",    label = "Gray 1  (darkest)",  color = function() return Blitbuffer.COLOR_GRAY_1    end },
    { key = "GRAY_2",    label = "Gray 2",             color = function() return Blitbuffer.COLOR_GRAY_2    end },
    { key = "GRAY_3",    label = "Gray 3",             color = function() return Blitbuffer.COLOR_GRAY_3    end },
    { key = "GRAY_4",    label = "Gray 4",             color = function() return Blitbuffer.COLOR_GRAY_4    end },
    { key = "GRAY_5",    label = "Gray 5",             color = function() return Blitbuffer.COLOR_GRAY_5    end },
    { key = "GRAY_6",    label = "Gray 6",             color = function() return Blitbuffer.COLOR_GRAY_6    end },
    { key = "GRAY_7",    label = "Gray 7",             color = function() return Blitbuffer.COLOR_GRAY_7    end },
    { key = "DARK_GRAY", label = "Dark gray",          color = function() return Blitbuffer.COLOR_DARK_GRAY end },
    { key = "GRAY_9",    label = "Gray 9",             color = function() return Blitbuffer.COLOR_GRAY_9    end },
    { key = "GRAY",      label = "Gray  (mid)",        color = function() return Blitbuffer.COLOR_GRAY      end },
    { key = "LIGHT_GRAY",label = "Light gray",         color = function() return Blitbuffer.COLOR_LIGHT_GRAY end },
    { key = "WHITE",     label = "White",              color = function() return Blitbuffer.COLOR_WHITE     end },
}
-- Hash map for O(1) key → color function lookup (replaces linear ipairs scan)
local DOTS_FILL_COLOR_LOOKUP = {}
for _, entry in ipairs(DOTS_FILL_COLOR_MAP) do
    DOTS_FILL_COLOR_LOOKUP[entry.key] = entry.color
end

local _dots_fill_color_cache = nil
local function getDotsFillColor()
    if _dots_fill_color_cache then return _dots_fill_color_cache end
    local key = get("progress_dots_fill_color")
    local fn = DOTS_FILL_COLOR_LOOKUP[key]
    _dots_fill_color_cache = fn and fn() or Blitbuffer.COLOR_BLACK  -- fallback
    return _dots_fill_color_cache
end

-- ── badge color helpers ────────────────────────────────────────────────────────
-- Badge background uses the same color palette as ball fill color.
local _badge_bg_color_cache = nil
local function getBadgeBgColor()
    if _badge_bg_color_cache then return _badge_bg_color_cache end
    local key = get("progress_badge_bg_color")
    local fn = DOTS_FILL_COLOR_LOOKUP[key]
    _badge_bg_color_cache = fn and fn() or Blitbuffer.COLOR_BLACK  -- fallback
    return _badge_bg_color_cache
end

local _badge_check_color_cache = nil
local function getBadgeCheckColor()
    if _badge_check_color_cache then return _badge_check_color_cache end
    local key = get("progress_badge_check_color") or "WHITE"
    _badge_check_color_cache = (key == "BLACK") and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    return _badge_check_color_cache
end

local _badge_fill_color_cache = nil
local function getBadgeFillColor()
    if _badge_fill_color_cache then return _badge_fill_color_cache end
    local key = get("pentagon_badge_fill_color") or "WHITE"
    local fn = DOTS_FILL_COLOR_LOOKUP[key]
    _badge_fill_color_cache = fn and fn() or Blitbuffer.COLOR_WHITE  -- fallback
    return _badge_fill_color_cache
end

local _cover_fill_color_cache = nil
local function getCoverFillColor()
    if _cover_fill_color_cache then return _cover_fill_color_cache end
    local key = get("cover_fill_color") or "WHITE"
    local fn = DOTS_FILL_COLOR_LOOKUP[key]
    _cover_fill_color_cache = fn and fn() or Blitbuffer.COLOR_WHITE  -- fallback
    return _cover_fill_color_cache
end

-- ── BIM cover-dims cache (filepath → {cw, ch, nb_pages, title, authors, series, series_index}) ──
-- Avoids repeated SQLite queries for the same book within a session.
-- All BIM fields needed by this patch (cover dims, page count, label metadata) are
-- stored together on the first query so getLabelText and getPageCount never need
-- to call bim:getBookInfo a second time for the same filepath.
-- A value of `false` means BIM was queried and returned no usable data for that
-- path, so subsequent renders skip the query entirely and fall back to the pixel
-- scan.  This sentinel prevents repeated failed BIM calls on un-indexed books.
local _bim_dims_cache = {}

-- ── arc lookup-table cache ────────────────────────────────────────────────────
-- Pre-computes integer half-chord pairs {outer_dx, inner_dx} for a circular arc
-- ring defined by (outer_r, inner_r).  The table is indexed by dy (0-based) and
-- covers dy = 0 .. outer_r inclusive.
--
-- Motivation: the outline arc loop in paintTo and the two arc loops in
-- paintProgressBadge each call math.sqrt twice per scanline row, for every item
-- in the grid.  Because outer_r depends on page_thickness and cover dimensions,
-- and inner_r = outer_r - page_thickness, the same (outer_r, inner_r) pair
-- repeats for every item of the same size on screen.  Caching amortises the
-- sqrt cost to a single computation per unique radius pair per session.
--
-- Key: outer_r * 10000 + inner_r — both are small integers so no collision risk,
-- and avoids allocating a string on every call (called multiple times per item).
local _arc_cache = {}
local function getArcTable(outer_r, inner_r)
    local key = outer_r * 10000 + inner_r
    if _arc_cache[key] then return _arc_cache[key] end
    local t = {}
    local rr  = outer_r  * outer_r
    local irr = inner_r  * inner_r
    for dy = 0, outer_r do
        local odx = math.floor(math.sqrt(math.max(0, rr  - dy * dy)) + 0.5)
        local idx = (inner_r > 0)
            and math.floor(math.sqrt(math.max(0, irr - dy * dy)) + 0.5)
            or  0
        t[dy] = { odx, idx }
    end
    _arc_cache[key] = t
    return t
end

-- ── per-item render cache ──────────────────────────────────────────────────────
-- Structure: _item_cache[filepath][item_w * 65536 + item_h]
--            → {left_off, top_off, cover_w, cover_h, name, num_lines}
-- Using a two-level table with an integer dim-key avoids the string
-- concatenation that itemCacheKey() previously performed on every paintTo
-- call — including on cache-hit paths where the string was immediately thrown away.
-- Populated on first render of each item; cleared on folder navigation.
-- Makes select-mode repaints and menu-behind-grid repaints essentially free.
local _item_cache = {}
local _spine_render_cache = {}
local _badge_render_cache = {}
local _filesize_pages_cache = {}
local _spine_bg_scratch = nil
local _cache_tick = 0
local SPINE_CACHE_MAX = 96
local BADGE_CACHE_MAX = 192

local function touchCacheEntry(entry)
    _cache_tick = _cache_tick + 1
    entry._stamp = _cache_tick
    return entry
end

local function evictOldestNestedCache(cache_tbl, max_entries, free_field)
    local count = 0
    local oldest_fp, oldest_dim, oldest_stamp, oldest_entry
    for fp, by_dim in pairs(cache_tbl) do
        for dim_key, entry in pairs(by_dim) do
            count = count + 1
            local stamp = entry and entry._stamp or 0
            if not oldest_stamp or stamp < oldest_stamp then
                oldest_fp, oldest_dim, oldest_stamp, oldest_entry = fp, dim_key, stamp, entry
            end
        end
    end
    if count > max_entries and oldest_fp and oldest_dim then
        if oldest_entry and free_field and oldest_entry[free_field] and oldest_entry[free_field].free then
            oldest_entry[free_field]:free()
        end
        cache_tbl[oldest_fp][oldest_dim] = nil
        if not next(cache_tbl[oldest_fp]) then
            cache_tbl[oldest_fp] = nil
        end
    end
end

local function evictOldestFlatCache(cache_tbl, max_entries, free_field)
    local count = 0
    local oldest_key, oldest_stamp, oldest_entry
    for key, entry in pairs(cache_tbl) do
        count = count + 1
        local stamp = entry and entry._stamp or 0
        if not oldest_stamp or stamp < oldest_stamp then
            oldest_key, oldest_stamp, oldest_entry = key, stamp, entry
        end
    end
    if count > max_entries and oldest_key then
        if oldest_entry and free_field and oldest_entry[free_field] and oldest_entry[free_field].free then
            oldest_entry[free_field]:free()
        end
        cache_tbl[oldest_key] = nil
    end
end

local function getItemCached(filepath, item_w, item_h)
    local t = _item_cache[filepath or ""]
    return t and t[item_w * 65536 + item_h]
end
local function setItemCached(filepath, item_w, item_h, val)
    local fp = filepath or ""
    local t  = _item_cache[fp]
    if not t then t = {}; _item_cache[fp] = t end
    t[item_w * 65536 + item_h] = val
end

local function getSpineRenderCached(filepath, item_w, item_h)
    local t = _spine_render_cache[filepath or ""]
    local entry = t and t[item_w * 65536 + item_h]
    if entry then touchCacheEntry(entry) end
    return entry
end
local function setSpineRenderCached(filepath, item_w, item_h, val)
    local fp = filepath or ""
    local dim_key = item_w * 65536 + item_h
    local t = _spine_render_cache[fp]
    if not t then
        t = {}
        _spine_render_cache[fp] = t
    end
    local old = t[dim_key]
    if old and old.rotated and old.rotated ~= val.rotated and old.rotated.free then
        old.rotated:free()
    end
    t[dim_key] = touchCacheEntry(val)
    evictOldestNestedCache(_spine_render_cache, SPINE_CACHE_MAX, "rotated")
end

local function getBadgeRenderCached(key)
    local entry = _badge_render_cache[key]
    if entry then touchCacheEntry(entry) end
    return entry
end
local function setBadgeRenderCached(key, val)
    local old = _badge_render_cache[key]
    if old and old.buf and old.buf ~= val.buf and old.buf.free then
        old.buf:free()
    end
    _badge_render_cache[key] = touchCacheEntry(val)
    evictOldestFlatCache(_badge_render_cache, BADGE_CACHE_MAX, "buf")
end

local function getSpineBgScratch(w, h, bb_type)
    if _spine_bg_scratch
            and _spine_bg_scratch.w == w
            and _spine_bg_scratch.h == h
            and _spine_bg_scratch.bb_type == bb_type then
        return _spine_bg_scratch.buf
    end
    if _spine_bg_scratch and _spine_bg_scratch.buf and _spine_bg_scratch.buf.free then
        _spine_bg_scratch.buf:free()
    end
    _spine_bg_scratch = {
        w = w,
        h = h,
        bb_type = bb_type,
        buf = Blitbuffer.new(w, h, bb_type),
    }
    return _spine_bg_scratch.buf
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
-- ── series prefix builder ─────────────────────────────────────────────────────
-- Returns a prefix string like "1# " or "2.5# " when series metadata is present
-- and the spine_series_prefix setting is enabled; otherwise returns "".
local function getSeriesPrefix(bookinfo)
    if not get("spine_series_prefix") then return "" end
    if not bookinfo then return "" end
    local series = bookinfo.series
    if not series or series == "" then return "" end
    local index  = bookinfo.series_index
    if index and index ~= "" then
        -- series_index may be stored as a number or string; format cleanly
        local n = tonumber(index)
        if n then
            -- drop trailing ".0" for whole numbers
            local fmt = (n == math.floor(n)) and ("%d#") or ("%.1f#")
            return fmt:format(n) .. " "
        else
            return tostring(index) .. "# "
        end
    else
        return ""  -- series name present but no index — nothing to prefix
    end
end

-- bookinfo_hint: optional table with {title, authors, series, series_index} fields
-- already fetched from BIM (stored in _bim_dims_cache).  When provided the BIM
-- query inside this function is skipped entirely, eliminating a duplicate SQLite
-- read for every uncached item whose cover dimensions came from BIM.
local function getLabelText(self, bookinfo_hint)
    local mode = get("text_mode")
    local raw  = self.filepath or self.text or ""

    -- Extract the bare filename once; used by the filename mode, the title-mode
    -- fallback, and the final fallback when BIM has no metadata.  Doing it here
    -- avoids calling splitFilePathName + splitFileNameSuffix more than once per
    -- slow-path item regardless of which branch is taken below.
    local _, _fname = util.splitFilePathName(raw)
    local bare_name = util.splitFileNameSuffix(_fname)

    if mode == "filename" then
        return bare_name
    end

    -- Use the pre-fetched bookinfo when available; fall back to a fresh BIM query
    -- only when the hint is absent (e.g. BIM was a miss and we have no cached data).
    local bookinfo = bookinfo_hint
    if not bookinfo then
        local bim = getBIM()
        if bim then
            local ok, bi = pcall(function() return bim:getBookInfo(raw, false) end)
            if ok then bookinfo = bi end
        end
    end

    if bookinfo then
        local title  = (bookinfo.title   and bookinfo.title   ~= "") and bookinfo.title   or nil
        local author = (bookinfo.authors and bookinfo.authors ~= "") and bookinfo.authors or nil
        local prefix = getSeriesPrefix(bookinfo)
        if mode == "title" then
            return prefix .. (title or bare_name)
        elseif mode == "author_title" then
            if author and title then return prefix .. author .. " – " .. title
            elseif title        then return prefix .. title
            elseif author       then return prefix .. author end
        elseif mode == "title_author" then
            if title and author then return prefix .. title .. " – " .. author
            elseif title        then return prefix .. title
            elseif author       then return prefix .. author end
        end
    end

    return bare_name
end

-- ── BIM metadata prefetch helper ──────────────────────────────────────────────
-- Normalizes the "query once, cache all useful fields, store false on miss"
-- pattern so paintTo(), getPageCount(), and the folder prepass all share one
-- implementation.
local function ensureBIMCache(filepath)
    if not filepath then return false end
    local cached_bim = _bim_dims_cache[filepath]
    if cached_bim ~= nil then return cached_bim end

    local bim = getBIM()
    if bim then
        local ok, bookinfo = pcall(function() return bim:getBookInfo(filepath, false) end)
        if ok and bookinfo then
            local has_dims = bookinfo.cover_w and bookinfo.cover_h
                         and bookinfo.cover_w > 0 and bookinfo.cover_h > 0
            local entry = {
                cw           = has_dims and bookinfo.cover_w or nil,
                ch           = has_dims and bookinfo.cover_h or nil,
                nb_pages     = bookinfo.nb_pages,
                title        = bookinfo.title,
                authors      = bookinfo.authors,
                series       = bookinfo.series,
                series_index = bookinfo.series_index,
            }
            if has_dims or entry.nb_pages or entry.title or entry.authors
                    or entry.series or entry.series_index then
                _bim_dims_cache[filepath] = entry
                return entry
            end
        end
    end

    _bim_dims_cache[filepath] = false
    return false
end

-- ── page count → line count ───────────────────────────────────────────────────
local _lines_cache = {}

-- Cached page-range thresholds array.  Rebuilt only when set() is called
-- (any settings write nils this).  Avoids 8 individual get() calls per
-- getNumLines() cache miss — one getRanges() call is amortised across all
-- items in the same folder view.
local _ranges_cache = nil
local _lines_enabled_cache = nil  -- parallel cache for the enabled flags
local function getRangesAndEnabled()
    if _ranges_cache then return _ranges_cache, _lines_enabled_cache end
    _ranges_cache = {
        get("page_range_2"),
        get("page_range_3"),
        get("page_range_4"),
        get("page_range_5"),
        get("page_range_6"),
        get("page_range_7"),
        get("page_range_8"),
        get("page_range_9"),
    }
    _lines_enabled_cache = {}
    for tier = 2, 10 do
        _lines_enabled_cache[tier] = get("lines_enabled_" .. tier)
    end
    return _ranges_cache, _lines_enabled_cache
end

-- ── unified DocSettings cache (filepath → {pages, percent, is_finished}) ────────
-- Opens each book's .sdr sidecar exactly once per folder load, extracting all
-- three fields in a single pass.  Both getPageCount and getReadingProgress read
-- from this cache, eliminating the duplicate DocSettings.open calls they
-- previously made independently.
local _docinfo_cache = {}

local function getDocSettingsData(filepath)
    if _docinfo_cache[filepath] then return _docinfo_cache[filepath] end
    local result = { pages = nil, percent = nil, is_finished = false }
    local ok, docinfo = pcall(DocSettings.open, DocSettings, filepath)
    if ok and docinfo and docinfo.data then
        -- page count
        if docinfo.data.doc_pages and docinfo.data.doc_pages > 0 then
            result.pages = docinfo.data.doc_pages
        elseif docinfo.data.stats and docinfo.data.stats.pages
                and docinfo.data.stats.pages ~= 0 then
            result.pages = docinfo.data.stats.pages
        end
        -- finished status
        if docinfo.data.summary and docinfo.data.summary.status then
            local s = docinfo.data.summary.status
            result.is_finished = (s == "complete" or s == "finished")
        end
        -- reading progress (0.0–1.0 float → 0–100 int)
        local pf = docinfo.data.percent_finished
        if type(pf) == "number" then
            result.percent = math.max(0, math.min(100, math.floor(pf * 100 + 0.5)))
        end
        if docinfo.close then pcall(function() docinfo:close() end) end
    end
    _docinfo_cache[filepath] = result
    return result
end

local function getPageCount(filepath)
    if not filepath then return nil end

    -- highest priority: explicit page count in filename e.g. "Book Title p234.epub"
    local fname = filepath:match("([^/]+)$") or ""
    local p = fname:match("[Pp]%((%d+)%)%.") or fname:match("[Pp](%d+)%.")
    if p then return tonumber(p) end

    -- DocSettings (shared open via getDocSettingsData — no duplicate file I/O)
    local ds = getDocSettingsData(filepath)
    if ds.pages then return ds.pages end

    -- BIM nb_pages: read from _bim_dims_cache when available so we never issue a
    -- second bim:getBookInfo call for a filepath already queried by the slow path.
    -- _bim_dims_cache[filepath] is:
    --   {cw,ch,nb_pages,…}  → BIM was queried; use nb_pages if present
    --   false               → BIM confirmed miss; skip query
    --   nil                 → not yet queried (e.g. getPageCount called before
    --                         paintTo's slow path) → fall through to live BIM query
    local cached_bim = ensureBIMCache(filepath)
    if cached_bim == false then
        -- confirmed BIM miss — skip the query entirely
    elseif cached_bim ~= nil then
        -- cache hit: nb_pages stored alongside cover dims
        if cached_bim.nb_pages and cached_bim.nb_pages > 0 then
            return cached_bim.nb_pages
        end
    end

    local cached_size_pages = _filesize_pages_cache[filepath]
    if cached_size_pages ~= nil then
        return cached_size_pages or nil
    end

    local ext = filepath:match("%.(%w+)$")
    if ext then ext = ext:lower() end
    local f = io.open(filepath, "rb")
    if f then
        local size = f:seek("end")
        f:close()
        if size and size > 0 then
            if ext == "epub" then
                local pages = math.max(1, math.floor(size / get("epub_bytes_per_page")))
                _filesize_pages_cache[filepath] = pages
                return pages
            elseif ext == "cbz" or ext == "cbr" then
                local pages = math.max(1, math.floor(size / (get("cbz_kb_per_page") * 1024)))
                _filesize_pages_cache[filepath] = pages
                return pages
            elseif ext == "pdf" then
                local pages = math.max(1, math.floor(size / (get("pdf_kb_per_page") * 1024)))
                _filesize_pages_cache[filepath] = pages
                return pages
            end
        end
    end

    _filesize_pages_cache[filepath] = false
    return nil
end

local function getNumLines(filepath)
    if not filepath then return 2 end
    if _lines_cache[filepath] then return _lines_cache[filepath] end

    local pages = getPageCount(filepath)
    if not pages then
        _lines_cache[filepath] = 4
        return 4
    end

    local max_lines = 10
    local ranges, enabled = getRangesAndEnabled()

    local n = max_lines
    for i = 1, max_lines - 1 do
        local tier = i + 1
        if enabled[tier] == false then goto continue end
        if pages <= (ranges[i] or math.huge) then
            n = tier
            break
        end
        ::continue::
    end
    while n > 2 and enabled[n] == false do
        n = n - 1
    end

    _lines_cache[filepath] = n
    return n
end

-- ── reading-progress resolver ─────────────────────────────────────────────────
-- Returns (percent_int_or_nil, is_finished_bool).
-- percent is 0-100; nil means the book has never been opened / no recorded progress.
-- 0 means opened and percent_finished is present but rounds to 0.
-- Reads from the unified _docinfo_cache (populated by getDocSettingsData) so the
-- .sdr file is never opened a second time per folder load.
local function getReadingProgress(filepath)
    if not filepath then return nil, false end
    local ds = getDocSettingsData(filepath)
    return ds.percent, ds.is_finished
end

-- ── folder-load metadata prepass ──────────────────────────────────────────────
-- Warm the caches for the first visible-ish chunk of books so the first mosaic
-- paints avoid on-demand BIM / DocSettings / filesize I/O.
local function primeVisibleBookCaches(items, limit)
    if type(items) ~= "table" then return end
    limit = math.max(0, math.min(limit or 48, #items))
    if limit == 0 then return end

    local needs_label_metadata = (get("text_mode") ~= "filename") or get("spine_series_prefix")
    local needs_num_lines      = get("enabled")
    local needs_progress       = get("progress_badge_enabled") or get("progress_dots_enabled")

    for i = 1, limit do
        local item = items[i]
        if type(item) == "table" and not item.is_directory then
            local filepath = item.filepath or item.text
            if filepath then
                if needs_label_metadata then
                    ensureBIMCache(filepath)
                end
                if needs_num_lines then
                    getNumLines(filepath)
                end
                if needs_progress then
                    getReadingProgress(filepath)
                end
            end
        end
    end
end

local function primeVisibleItemGeometry(items, limit)
    if type(items) ~= "table" or not get("enabled") then return end
    -- When cover pixels will be resampled (aspect-ratio/stretch mode or scale%),
    -- the first paint needs to work from the cover box KOReader actually drew,
    -- not an eagerly seeded geometry guess. Otherwise we can sample surrounding
    -- whitespace and end up stretching bars into the first render.
    if get("aspect_enabled") or get("cover_scale_pct") ~= 100 then return end
    limit = math.max(0, math.min(limit or 24, #items))
    if limit == 0 then return end

    for i = 1, limit do
        local item = items[i]
        if type(item) == "table" and not item.is_directory then
            local filepath = item.filepath or item.text
            local dimen = item.dimen
            local item_w = (dimen and dimen.w) or item.width or 0
            local item_h = (dimen and dimen.h) or item.height or 0
            if filepath and item_w > 0 and item_h > 0 and not getItemCached(filepath, item_w, item_h) then
                local cached_bim = ensureBIMCache(filepath)
                if cached_bim and cached_bim.cw and cached_bim.ch then
                    local scale = math.min(item_w / cached_bim.cw, item_h / cached_bim.ch)
                    local cover_w = math.floor(cached_bim.cw * scale)
                    local cover_h = math.floor(cached_bim.ch * scale)
                    if cover_w > 4 and cover_h > 4 then
                        local left_off = math.floor((item_w - cover_w) / 2)
                        local top_off  = math.floor((item_h - cover_h) / 2)
                        local fake_self = { filepath = filepath, text = item.text }
                        setItemCached(filepath, item_w, item_h, {
                            left_off  = left_off,
                            top_off   = top_off,
                            cover_w   = cover_w,
                            cover_h   = cover_h,
                            name      = getLabelText(fake_self, cached_bim),
                            num_lines = getNumLines(filepath),
                        })
                    end
                end
            end
        end
    end
end

-- Cache structure: _badge_fs_cache[inner_w][inner_h][text_str] = {fs, tw, th}
-- tw/th are the measured pixel dimensions at the winning font size.
-- Storing tw/th alongside fs means a cache hit never needs to create a TextWidget
-- just to verify the size — we already know it fits.  The widget is only built
-- once the cache confirms (or establishes) the winning fs.
-- Integer dimension keys avoid string allocation on every call.
-- Cache is intentionally never cleared (badge geometry only changes on cover
-- resize or settings change, both of which are rare and bounded).
local _badge_fs_cache = {}

-- Finds the largest font size that fits text_str inside inner_w × inner_h,
-- starting from initial_fs and stepping down to min 6.
--
-- bump_fs (optional int): added to the winning fs before building the returned
--   widget (used by checkmark callers which always want fs+3 for visual weight).
--   The cache always stores the *fitting* fs; bump_fs only affects the widget
--   returned to the caller and is never written to the cache.
--
-- Returns (fs, tw, ts) where:
--   fs  = winning fit size (before bump_fs)
--   tw  = live TextWidget at (fs + bump_fs) — caller must free it
--   ts  = tw:getSize() result
local function fitBadgeTextSize(text_str, inner_w, inner_h, initial_fs, check_color, bump_fs)
    bump_fs = bump_fs or 0

    -- ── cache lookup ──────────────────────────────────────────────────────────
    local t1    = _badge_fs_cache[inner_w]
    local t2    = t1 and t1[inner_h]
    local entry = t2 and t2[text_str]

    local fs
    if entry then
        -- Fast path: winning fs and its pixel dimensions are already known.
        -- No widget needed to verify fit — just build at the (possibly bumped) size.
        fs = entry[1]
        local render_fs = fs + bump_fs
        local tw = TextWidget:new{
            text    = text_str,
            face    = getFaceCached("NotoSans-Bold.ttf", render_fs),
            fgcolor = check_color,
        }
        local ts = (bump_fs == 0) and { w = entry[2], h = entry[3] } or tw:getSize()
        return fs, tw, ts
    end

    -- ── cache miss: search downward from initial_fs ───────────────────────────
    fs = initial_fs
    local tw, ts
    for _ = 1, math.max(1, fs - 6 + 1) do
        tw = TextWidget:new{
            text    = text_str,
            face    = getFaceCached("NotoSans-Bold.ttf", fs),
            fgcolor = check_color,
        }
        ts = tw:getSize()
        if ts.w <= inner_w and ts.h <= inner_h then break end
        tw:free()
        fs = math.max(6, fs - 1)
        if fs == 6 then
            tw = TextWidget:new{
                text    = text_str,
                face    = getFaceCached("NotoSans-Bold.ttf", fs),
                fgcolor = check_color,
            }
            ts = tw:getSize()
            break
        end
    end

    -- store {fs, pixel_w, pixel_h} so future hits skip widget creation entirely
    if not _badge_fs_cache[inner_w] then _badge_fs_cache[inner_w] = {} end
    if not _badge_fs_cache[inner_w][inner_h] then _badge_fs_cache[inner_w][inner_h] = {} end
    _badge_fs_cache[inner_w][inner_h][text_str] = { fs, ts.w, ts.h }

    -- If a bump was requested we need a widget at the bumped size.
    -- The fit widget (at plain fs) is no longer needed — free it and rebuild.
    if bump_fs ~= 0 then
        tw:free()
        local render_fs = fs + bump_fs
        tw = TextWidget:new{
            text    = text_str,
            face    = getFaceCached("NotoSans-Bold.ttf", render_fs),
            fgcolor = check_color,
        }
        ts = tw:getSize()
    end

    return fs, tw, ts
end

local function getOrBuildBadgeBuffer(cache_key, bb, src_x, src_y, w, h, build_fn)
    local cached = getBadgeRenderCached(cache_key)
    if cached then return cached.buf end
    local tmp = Blitbuffer.new(w, h, bb:getType())
    tmp:blitFrom(bb, 0, 0, src_x, src_y, w, h)
    build_fn(tmp)
    setBadgeRenderCached(cache_key, { buf = tmp })
    return tmp
end

-- ── progress badge painter ────────────────────────────────────────────────────
-- White filled rectangle with rounded top-left corner, anchored at the
-- bottom-right corner of the cover flush against the inside of the outline.
-- The outline's right/bottom bars and corner arc form the right/bottom border.
-- Black border on top and left edges only.
--
-- outline_r – same corner radius used by the outline arc.  We redraw the arc
--             on top of the fill so the corner is never overwritten.
local function paintProgressBadge(bb, filepath, cover_x, cover_y, cover_w, cover_h,
                                   percent, is_finished, ot, outline_r, badge_alpha, position,
                                   bg_color, check_color)
    if not percent and not is_finished then return end

    ot          = ot          or 2
    outline_r   = outline_r   or ot
    badge_alpha = badge_alpha or 1.0
    position    = position    or "bottom_right"

    -- Badge is always on the right side; position controls top vs bottom
    local at_bottom = (position ~= "top_right")
    local at_right  = true

    -- Badge dimensions (shared with bookmark shapes via pentagon_badge_* settings)
    local Rx = math.max(18, math.floor(cover_w * get("pentagon_badge_w_pct") / 1000))
    local total_h = math.max(22, math.floor(cover_h * get("pentagon_badge_h_pct") / 1000))
    local rect_pct = get("pentagon_badge_rect_pct") / 1000
    local Ry = math.max(16, math.floor(total_h * rect_pct))

    -- Anchor corner: always the right edge, top or bottom
    local ax = cover_x + cover_w - 1 - ot
    local ay
    if at_bottom then
        ay = cover_y + cover_h - 1 - ot
    else
        ay = cover_y + ot
    end

    -- Badge extents (bx/bt = top-left of badge bounding box)
    local bx = ax - Rx + 1
    local bt
    if at_bottom then
        bt = ay - Ry + 1
    else
        bt = ay            -- top anchor: badge extends downward
    end

    -- The "free" corner of the badge (top-left when at_bottom, bottom-left when at_top).
    local rc       = math.max(4, math.floor(math.min(Rx, Ry) * 0.27))
    local rc_inner = math.max(0, rc - ot)

    -- free corner of badge bounding box: always the left edge (bx), top or bottom
    local fcx_bb = bx
    local fcy_bb = at_bottom and bt or (bt + Ry - 1)

    -- arc centre offset inward from the free corner (always rightward from left edge)
    local arc_cx = fcx_bb + rc
    local arc_cy = at_bottom and (fcy_bb + rc) or (fcy_bb - rc)

    -- Outline corner arc geometry (cover's right corner, top or bottom)
    local outline_cx = cover_x + cover_w - outline_r
    local outline_cy
    if at_bottom then
        outline_cy = cover_y + cover_h - 1 - outline_r
    else
        outline_cy = cover_y + outline_r
    end
    local r_inner    = math.max(0, outline_r - ot)

    -- ── 1. Alpha-blended black fill + fully-opaque white text on tmp ─────────
    local badge_w    = Rx
    local badge_h_px = Ry
    if badge_w <= 0 or badge_h_px <= 0 then return end

    local blend_val     = math.floor(badge_alpha * 255)
    bg_color    = bg_color    or Blitbuffer.COLOR_BLACK
    check_color = check_color or Blitbuffer.COLOR_WHITE
    local bg_r = bg_color:getR()
    local bg_g = bg_color:getG()
    local bg_b = bg_color:getB()
    local badge_bg_color = Blitbuffer.ColorRGB32(bg_r, bg_g, bg_b, blend_val)
    local text_str = is_finished and "\xe2\x9c\x93" or (tostring(percent) .. "%")
    local cache_key = string.format("rect:%s:%d:%d:%d:%d:%d:%d:%.4g:%s:%d:%d:%d:%d:%d:%d:%d",
        filepath or "",
        cover_w, cover_h, percent or -1, is_finished and 1 or 0,
        ot, outline_r, badge_alpha, position or "",
        bg_r, bg_g, bg_b,
        check_color == Blitbuffer.COLOR_BLACK and 0 or 1,
        badge_w, badge_h_px, rc)
    local tmp = getOrBuildBadgeBuffer(cache_key, bb, bx, bt, badge_w, badge_h_px, function(tmp)

        -- Fill the badge shape row by row, clipping the free rounded corner (always top-left or bottom-left)
        for py = 0, badge_h_px - 1 do
            local abs_py = bt + py
            local xl = 0

            local in_corner_row
            if at_bottom then
                in_corner_row = abs_py < (bt + rc)
            else
                in_corner_row = abs_py >= (bt + Ry - rc)
            end

            if in_corner_row then
                local dy_corner
                if at_bottom then
                    dy_corner = (bt + rc) - abs_py
                else
                    dy_corner = abs_py - (bt + Ry - rc - 1)
                end
                local chord = math.floor(math.sqrt(math.max(0, rc * rc - dy_corner * dy_corner)) + 0.5)
                xl = rc - chord   -- clip left side (free corner is always on the left)
            end

            local run = badge_w - xl
            if run > 0 then
                tmp:blendRectRGB32(xl, py, run, 1, badge_bg_color)
            end
        end

        -- (c) paint white text/checkmark onto tmp
        local text_left  = bx + ot + 1
        local text_right = bx + Rx - ot - 1
        local inner_w    = text_right - text_left
        local inner_h    = Ry - 2 * ot

        local initial_fs = math.max(6, math.floor(math.min(Rx, Ry) * 0.52 / getDPIScale()))
        local badge_fs, tw, ts
        if is_finished then
            badge_fs, tw, ts = fitBadgeTextSize(text_str, inner_w, inner_h, initial_fs, check_color, 3)
            badge_fs = badge_fs + 3
        else
            badge_fs, tw, ts = fitBadgeTextSize(text_str, inner_w, inner_h, initial_fs, check_color)
        end

        local usable_cx  = math.floor((text_left + text_right) / 2)
        local badge_mid_y = bt + math.floor(badge_h_px * 0.5)
        local tx = math.max(text_left, usable_cx - math.floor(ts.w / 2))
        local ty = badge_mid_y - math.floor(ts.h / 2)
        tw:paintTo(tmp, tx - bx, ty - bt)
        tw:free()
    end)

    -- (d) blit composited badge onto bb
    bb:blitFrom(tmp, bx, bt, 0, 0, badge_w, badge_h_px)

    -- ── 2. Redraw the outline corner arc on top of the fill ───────────────────
    local outline_arc_tbl = getArcTable(outline_r, r_inner)
    for d = 1, outline_r do
        local pair    = outline_arc_tbl[d]
        local outer_d = pair[1]
        local inner_d = pair[2]
        local ring_len = outer_d - inner_d + 1
        local x0 = math.min(outline_cx + inner_d, cover_x + cover_w - 1)
        local row
        if at_bottom then
            row = outline_cy + d
            if row > (cover_y + cover_h - 1) then break end
        else
            row = outline_cy - d
            if row < cover_y then break end
        end
        if ring_len > 0 then bb:paintRect(x0, row, ring_len, 1, Blitbuffer.COLOR_BLACK) end
    end

    -- ── 3. Black border on the two free edges of the badge ───────────────────
    -- Horizontal free edge: top of badge if at_bottom, bottom if at_top
    local h_edge_y = at_bottom and bt or (bt + Ry - ot)
    local h_edge_x = arc_cx + 1
    local h_edge_len = (bx + Rx - 1) - arc_cx
    if h_edge_len > 0 then
        bb:paintRect(h_edge_x, h_edge_y, h_edge_len, ot, Blitbuffer.COLOR_BLACK)
    end

    -- Vertical free edge: always the left edge of the badge
    local v_edge_x = bx
    local v_edge_y = at_bottom and (arc_cy + 1) or bt
    local v_edge_len
    if at_bottom then
        v_edge_len = (bt + Ry - 1) - arc_cy
    else
        v_edge_len = arc_cy - bt
    end
    if v_edge_len > 0 then
        bb:paintRect(v_edge_x, v_edge_y, ot, v_edge_len, Blitbuffer.COLOR_BLACK)
    end

    -- Rounded free corner arc (always top-left or bottom-left)
    local corner_arc_tbl = getArcTable(rc, rc_inner)
    for dy = 0, rc do
        local pair     = corner_arc_tbl[dy]
        local outer_dx = pair[1]
        local inner_dx = pair[2]
        local ring_len2 = outer_dx - inner_dx
        if ring_len2 > 0 then
            local row
            if at_bottom then
                row = arc_cy - dy   -- arc opens upward (top-left corner)
            else
                row = arc_cy + dy   -- arc opens downward (bottom-left corner)
            end
            if row >= bt and row < bt + badge_h_px then
                bb:paintRect(arc_cx - outer_dx, row, ring_len2, 1, Blitbuffer.COLOR_BLACK)
            end
        end
    end
end

-- ── pentagon badge painter ────────────────────────────────────────────────────
-- Draws an upside-down house (▽-like pentagon) anchored at the top edge of the
-- cover with a 10% right margin from the cover's right outline.
--
-- Shape: flat top, two vertical sides that drop partway down, then two diagonal
-- sides meeting at a downward point.  Text is centred in the upper rectangular
-- portion.  Border and fill use the same bg_color / check_color as the standard
-- badge.  The flat-top edge aligns flush with the top outline bar; the shape
-- hangs downward into the cover.
--
-- Layout (all values relative to cover coords):
--   right anchor : cover right edge  −  10% of cover_w  −  ot
--   width  (W)   : ~20% of cover_w, at least 18px
--   rect height  : ~55% of total height  (text lives here)
--   total height : ~25% of cover_h, at least 22px
--   tip depth    : total_h − rect_h  (the triangular point)
local function paintProgressBadgePentagon(bb, filepath, cover_x, cover_y, cover_w, cover_h,
                                           percent, is_finished, ot, badge_alpha,
                                           bg_color, check_color)
    if not percent and not is_finished then return end

    ot          = ot          or 2
    badge_alpha = badge_alpha or 1.0
    bg_color    = bg_color    or Blitbuffer.COLOR_BLACK
    check_color = check_color or Blitbuffer.COLOR_WHITE

    -- ── geometry ──────────────────────────────────────────────────────────────
    local W        = math.max(18, math.floor(cover_w * get("pentagon_badge_w_pct") / 1000))
    local total_h  = math.max(22, math.floor(cover_h * get("pentagon_badge_h_pct") / 1000))
    local rect_h   = math.max(1, math.floor(total_h * get("pentagon_badge_rect_pct") / 1000))  -- flat rectangular top portion
    local tri_h    = total_h - rect_h               -- triangular tip portion

    -- right edge of the badge: configurable margin from the cover's right outline
    local right_margin = math.max(ot + 1, math.floor(cover_w * get("pentagon_badge_right_margin_pct") / 1000))
    local bx_right = cover_x + cover_w - 1 - ot - right_margin  -- rightmost x of badge
    local bx_left  = bx_right - W + 1
    local bt       = cover_y                                    -- top y: sits on the outside of the cover outline
    local bb_rect  = bt + rect_h - 1                            -- bottom of rectangular part
    local tip_y    = bt + total_h - 1                           -- y of the downward tip pixel

    if W <= 0 or total_h <= 0 then return end

    local blend_val     = math.floor(badge_alpha * 255)
    local bg_r          = bg_color:getR()
    local bg_g          = bg_color:getG()
    local bg_b          = bg_color:getB()
    local badge_bg_col  = Blitbuffer.ColorRGB32(bg_r, bg_g, bg_b, blend_val)
    local tmp_w = W
    local tmp_h = total_h
    local fill_mode = get("pentagon_badge_fill_mode")
    local text_str = is_finished and "\xe2\x9c\x93" or (tostring(percent) .. "%")
    local cache_key = string.format("pent:%s:%d:%d:%d:%d:%d:%.4g:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%s",
        filepath or "",
        cover_w, cover_h, percent or -1, is_finished and 1 or 0,
        ot, badge_alpha, bg_r, bg_g, bg_b,
        check_color == Blitbuffer.COLOR_BLACK and 0 or 1,
        W, total_h, rect_h,
        get("pentagon_badge_w_pct"), get("pentagon_badge_h_pct"),
        get("pentagon_badge_rect_pct"), get("pentagon_badge_right_margin_pct"),
        fill_mode and 1 or 0,
        get("pentagon_badge_fill_color") or "")
    local tmp = getOrBuildBadgeBuffer(cache_key, bb, bx_left, bt, tmp_w, tmp_h, function(tmp)

    -- fill scanlines: rectangular top, then triangular taper
    for py = 0, tmp_h - 1 do
        local xl, xr
        if py < rect_h then
            -- rectangular section: full width
            xl = 0
            xr = W - 1
        else
            -- triangular taper: linearly narrows to 1px at tip
            local t   = (py - rect_h) / math.max(1, tri_h - 1)  -- 0..1
            local half = math.floor((W / 2) * (1 - t) + 0.5)
            half       = math.max(0, half)
            local cx_l = math.floor(W / 2)
            xl = cx_l - half
            xr = cx_l + half
        end
        local run = xr - xl + 1
        if run > 0 then
            tmp:blendRectRGB32(xl, py, run, 1, badge_bg_col)
        end
    end

    -- ── text or fill-mode rendering ───────────────────────────────────────────
    if fill_mode and not is_finished then
        -- Fill mode: paint a semi-transparent check_color overlay from the top
        -- of the badge downward, proportional to reading progress, covering
        -- both the rectangular body AND the triangular tip.
        local pct_val   = math.max(0, math.min(100, percent or 0))
        local fill_rows = math.floor(pct_val * total_h / 100 + 0.5)
        if fill_rows > 0 then
            local fill_col = getBadgeFillColor()
            local fill_overlay = Blitbuffer.ColorRGB32(fill_col:getR(), fill_col:getG(), fill_col:getB(), 200)
            local half_w = W / 2
            for py = 0, fill_rows - 1 do
                local xl, run
                if py < rect_h then
                    -- rectangular section: full width
                    xl  = 0
                    run = W
                else
                    -- triangular taper: same formula as the fill scanline above
                    local t    = (py - rect_h) / math.max(1, tri_h - 1)
                    local half = math.floor(half_w * (1 - t) + 0.5)
                    half = math.max(0, half)
                    local cx_l = math.floor(W / 2)
                    xl  = cx_l - half
                    run = 2 * half + 1
                end
                if run > 0 then tmp:blendRectRGB32(xl, py, run, 1, fill_overlay) end
            end
            -- 1px separator line at the fill boundary (only if not fully filled)
            if fill_rows < total_h then
                local py = fill_rows
                local xl, run
                if py < rect_h then
                    xl  = 0
                    run = W
                else
                    local t    = (py - rect_h) / math.max(1, tri_h - 1)
                    local half = math.floor((W / 2) * (1 - t) + 0.5)
                    half = math.max(0, half)
                    local cx_l = math.floor(W / 2)
                    xl  = cx_l - half
                    run = 2 * half + 1
                end
                if run > 0 then tmp:paintRect(xl, py, run, 1, Blitbuffer.COLOR_BLACK) end
            end
        end
    else
        -- Text / checkmark mode (original behaviour)
        local text_str = is_finished and "\xe2\x9c\x93" or (tostring(percent) .. "%")
        local inner_w  = W - 2
        local inner_h  = rect_h - 2
        local initial_fs = math.max(6, inner_h)
        local badge_fs, tw, ts
        if is_finished then
            badge_fs, tw, ts = fitBadgeTextSize(text_str, inner_w, inner_h, initial_fs, check_color, 3)
            badge_fs = badge_fs + 3
        else
            badge_fs, tw, ts = fitBadgeTextSize(text_str, inner_w, inner_h, initial_fs, check_color)
        end
        local tx = math.floor((W - ts.w) / 2)
        local ty
        if is_finished then
            ty = math.max(0, rect_h - 1 - ts.h)  -- pin checkmark to bottom of body
        else
            ty = rect_h - ts.h  -- bottom of text flush with the diagonal boundary
        end
        tw:paintTo(tmp, tx, ty)
        tw:free()
    end
    end)

    -- blit blended badge onto bb
    bb:blitFrom(tmp, bx_left, bt, 0, 0, tmp_w, tmp_h)

    -- ── border on top and sides ───────────────────────────────────────────────
    -- Top edge is the cover outline itself — no separate top border needed.
    -- Left vertical edge (rectangular section)
    bb:paintRect(bx_left, bt, ot, rect_h, Blitbuffer.COLOR_BLACK)
    -- Right vertical edge (rectangular section)
    bb:paintRect(bx_right - ot + 1, bt, ot, rect_h, Blitbuffer.COLOR_BLACK)
    -- Diagonal sides of the triangle (rect_h .. tip_y)
    -- The diagonal runs dx=(W/2) horizontally over dy=tri_h vertically.
    -- A horizontal stroke of width `ot` has apparent perpendicular thickness
    -- ot*sin(angle). To match the visual weight of the vertical bars we need
    -- a horizontal stroke width of ceil(ot / sin(angle)) where
    -- sin(angle) = tri_h / sqrt(tri_h^2 + (W/2)^2).
    local half_w   = W / 2
    local diag_len = math.sqrt(tri_h * tri_h + half_w * half_w)
    local diag_sin = (diag_len > 0) and (tri_h / diag_len) or 1
    local diag_ot  = (diag_sin > 0) and math.ceil(ot / diag_sin) or ot
    for py = 0, tri_h - 1 do
        local t    = py / math.max(1, tri_h - 1)
        local half = math.floor(half_w * (1 - t) + 0.5)
        local cx_l = bx_left + math.floor(W / 2)
        local lx   = cx_l - half
        local l_w = math.min(diag_ot, cx_l - lx)          -- clamp: don't cross cx_l
        if l_w > 0 then bb:paintRect(lx, bt + rect_h + py, l_w, 1, Blitbuffer.COLOR_BLACK) end
        local rx  = math.max(cx_l + half - diag_ot + 1, cx_l) -- clamp: don't start before cx_l
        local r_w = cx_l + half - rx + 1
        if r_w > 0 then bb:paintRect(rx, bt + rect_h + py, r_w, 1, Blitbuffer.COLOR_BLACK) end
    end
    -- tip pixel
    bb:paintRect(bx_left + math.floor(W / 2), tip_y, 1, 1, Blitbuffer.COLOR_BLACK)
end

-- ── W-badge geometry cache ────────────────────────────────────────────────────
-- Pre-builds the notch half-width lookup array for a given (W, total_h, rect_h)
-- geometry so paintProgressBadgeW never allocates closures:
--
--   geom.notch[py]  – half-width of the notch between the W teeth for
--                     py = rect_h .. total_h-1  (replaces notchHalf closure)
--
-- Key encodes all three inputs as a compact integer tuple; both W and total_h
-- are bounded by cover dimensions so no overflow risk.
local _w_badge_geom_cache = {}
local function getWBadgeGeom(W, total_h, rect_h)
    local key = W * 10000000 + total_h * 10000 + rect_h
    local cached = _w_badge_geom_cache[key]
    if cached then return cached end

    local tri_h   = total_h - rect_h
    local cx      = math.floor(W / 2)
    local tip_row = rect_h + tri_h - 1
    local curve_r = math.max(2, math.floor(cx * 0.35 + 0.5))

    -- notch[py]: pre-computed notchHalf for the teeth section (py >= rect_h)
    local notch = {}
    if tri_h > 0 then
        for py = rect_h, total_h - 1 do
            local t      = (py - rect_h) / tri_h
            t = math.max(0, math.min(1, t))
            local lin_nh = math.floor(cx * t + 0.5)
            local dy     = tip_row - py
            if dy < curve_r then
                local arc_nh = math.floor(math.sqrt(math.max(0,
                    curve_r * curve_r - dy * dy)) + 0.5)
                notch[py] = math.max(lin_nh, arc_nh)
            else
                notch[py] = lin_nh
            end
        end
    end

    cached = { notch = notch, cx = cx }
    _w_badge_geom_cache[key] = cached
    return cached
end

-- ── W-shape badge painter ─────────────────────────────────────────────────────
-- Flat top rectangle (text lives here), then a W bottom:
--   • Two outer edges taper straight inward to a SINGLE shared centre tip.
--   • The inner "valley" between the teeth uses a quadratic curve: it rises
--     from rect_h at the outer quarter-points up to full rect_h at the centre,
--     creating a smooth U-shaped notch rather than a hard V.
-- All sizing settings (w_pct, h_pct, rect_pct, right_margin_pct) shared with pentagon.
local function paintProgressBadgeW(bb, filepath, cover_x, cover_y, cover_w, cover_h,
                                    percent, is_finished, ot, badge_alpha,
                                    bg_color, check_color)
    if not percent and not is_finished then return end

    ot          = ot          or 2
    badge_alpha = badge_alpha or 1.0
    bg_color    = bg_color    or Blitbuffer.COLOR_BLACK
    check_color = check_color or Blitbuffer.COLOR_WHITE

    -- ── geometry ──────────────────────────────────────────────────────────────
    local W       = math.max(18, math.floor(cover_w * get("pentagon_badge_w_pct") / 1000))
    local total_h = math.max(22, math.floor(cover_h * get("pentagon_badge_h_pct") / 1000))
    local rect_h  = math.max(1, math.floor(total_h * get("pentagon_badge_rect_pct") / 1000))
    local tri_h   = total_h - rect_h

    local right_margin = math.max(ot + 1, math.floor(cover_w * get("pentagon_badge_right_margin_pct") / 1000))
    local bx_right = cover_x + cover_w - 1 - ot - right_margin
    local bx_left  = bx_right - W + 1
    local bt       = cover_y
    local tip_y    = bt + total_h - 1

    if W <= 0 or total_h <= 0 then return end

    -- ── pre-built scanline tables (replaces notchHalf closure) ──────────────────
    -- getWBadgeGeom returns a cached notch array so every per-row lookup is a
    -- plain table read instead of a closure call with floating-point arithmetic.
    local geom  = getWBadgeGeom(W, total_h, rect_h)
    local cx    = geom.cx     -- centre column in tmp coords
    local notch = geom.notch  -- notch[py] → notchHalf result for py >= rect_h

    -- ── alpha-blend fill ──────────────────────────────────────────────────────
    local blend_val    = math.floor(badge_alpha * 255)
    local badge_bg_col = Blitbuffer.ColorRGB32(bg_color:getR(), bg_color:getG(), bg_color:getB(), blend_val)
    local tmp_w  = W
    local tmp_h  = total_h
    local tmp_bx = bx_left
    local fill_mode = get("pentagon_badge_fill_mode")
    local text_str = is_finished and "\xe2\x9c\x93" or (tostring(percent) .. "%")
    local cache_key = string.format("w:%s:%d:%d:%d:%d:%d:%.4g:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%s",
        filepath or "",
        cover_w, cover_h, percent or -1, is_finished and 1 or 0,
        ot, badge_alpha,
        bg_color:getR(), bg_color:getG(), bg_color:getB(),
        check_color == Blitbuffer.COLOR_BLACK and 0 or 1,
        W, total_h, rect_h,
        get("pentagon_badge_w_pct"), get("pentagon_badge_h_pct"),
        get("pentagon_badge_rect_pct"), get("pentagon_badge_right_margin_pct"),
        fill_mode and 1 or 0,
        get("pentagon_badge_fill_color") or "")
    local tmp = getOrBuildBadgeBuffer(cache_key, bb, tmp_bx, bt, tmp_w, tmp_h, function(tmp)

    -- Scanline fill
    for py = 0, tmp_h - 1 do
        if py < rect_h then
            -- rectangular section: straight vertical sides
            if W > 0 then tmp:blendRectRGB32(0, py, W, 1, badge_bg_col) end
        else
            local nh = notch[py]
            local left_run = cx - nh
            if left_run > 0 then
                tmp:blendRectRGB32(0, py, left_run, 1, badge_bg_col)
            end
            local right_x   = cx + nh
            local right_run = W - right_x
            if right_run > 0 then
                tmp:blendRectRGB32(right_x, py, right_run, 1, badge_bg_col)
            end
            if left_run <= 0 and right_run <= 0 then
                tmp:blendRectRGB32(0,     py, 1, 1, badge_bg_col)
                tmp:blendRectRGB32(W - 1, py, 1, 1, badge_bg_col)
            end
        end
    end

    -- ── text or fill-mode rendering ───────────────────────────────────────────
    if fill_mode and not is_finished then
        -- Fill mode: paint a semi-transparent check_color overlay from the top
        -- of the badge downward, proportional to reading progress, covering
        -- both the rectangular body AND the W-shaped teeth.
        local pct_val   = math.max(0, math.min(100, percent or 0))
        local fill_rows = math.floor(pct_val * total_h / 100 + 0.5)
        if fill_rows > 0 then
            local fill_col = getBadgeFillColor()
            local fill_overlay = Blitbuffer.ColorRGB32(fill_col:getR(), fill_col:getG(), fill_col:getB(), 200)
            for py = 0, fill_rows - 1 do
                if py < rect_h then
                    -- rectangular section: straight vertical sides
                    if W > 0 then tmp:blendRectRGB32(0, py, W, 1, fill_overlay) end
                else
                    -- W teeth section: two filled lobes separated by the notch
                    local nh = notch[py]
                    local left_run = cx - nh
                    if left_run > 0 then
                        tmp:blendRectRGB32(0, py, left_run, 1, fill_overlay)
                    end
                    local right_x   = cx + nh
                    local right_run = W - right_x
                    if right_run > 0 then
                        tmp:blendRectRGB32(right_x, py, right_run, 1, fill_overlay)
                    end
                end
            end
            -- 1px separator line at the fill boundary (only if not fully filled)
            if fill_rows < total_h then
                local py = fill_rows
                if py < rect_h then
                    if W > 0 then tmp:paintRect(0, py, W, 1, Blitbuffer.COLOR_BLACK) end
                else
                    local nh = notch[py]
                    local left_run = cx - nh
                    if left_run > 0 then
                        tmp:paintRect(0, py, left_run, 1, Blitbuffer.COLOR_BLACK)
                    end
                    local right_x   = cx + nh
                    local right_run = W - right_x
                    if right_run > 0 then
                        tmp:paintRect(right_x, py, right_run, 1, Blitbuffer.COLOR_BLACK)
                    end
                end
            end
        end
    else
        -- Text / checkmark mode (original behaviour)
        local inner_w  = W - 2
        local inner_h  = rect_h - 2
        local initial_fs = math.max(6, inner_h)
        local badge_fs, tw, ts
        if is_finished then
            badge_fs, tw, ts = fitBadgeTextSize(text_str, inner_w, inner_h, initial_fs, check_color, 3)
            badge_fs = badge_fs + 3
        else
            badge_fs, tw, ts = fitBadgeTextSize(text_str, inner_w, inner_h, initial_fs, check_color)
        end
        local tx = math.floor((W - ts.w) / 2)
        local ty
        if is_finished then
            ty = math.max(0, rect_h - 1 - ts.h)  -- pin checkmark to bottom of body
        else
            ty = rect_h - ts.h
        end
        tw:paintTo(tmp, tx, ty)
        tw:free()
    end
    end)

    bb:blitFrom(tmp, tmp_bx, bt, 0, 0, tmp_w, tmp_h)

    -- ── border ────────────────────────────────────────────────────────────────
    -- Vertical rect sides: straight lines on both edges.
    bb:paintRect(bx_left,           bt, ot, rect_h, Blitbuffer.COLOR_BLACK)
    bb:paintRect(bx_right - ot + 1, bt, ot, rect_h, Blitbuffer.COLOR_BLACK)
    -- W teeth borders: outer edges are straight vertical (already correct thickness).
    -- Inner notch edges are diagonal — apply the same perpendicular-thickness
    -- correction as the pentagon: the notch half-width goes from cx at rect_h to 0
    -- at the tip, so sin(angle) = tri_h / sqrt(tri_h^2 + cx^2).
    local w_diag_len = math.sqrt(tri_h * tri_h + cx * cx)
    local w_diag_sin = (w_diag_len > 0) and (tri_h / w_diag_len) or 1
    local w_diag_ot  = (w_diag_sin > 0) and math.ceil(ot / w_diag_sin) or ot
    for py = 0, tri_h - 1 do
        local abs_y = bt + rect_h + py
        local nh    = notch[rect_h + py]
        bb:paintRect(bx_left,                   abs_y, ot, 1, Blitbuffer.COLOR_BLACK)
        bb:paintRect(bx_right - ot + 1,         abs_y, ot, 1, Blitbuffer.COLOR_BLACK)
        local il = bx_left + (cx - nh)
        if il >= bx_left + ot then
            local l_w = math.min(w_diag_ot, bx_left + cx - il) -- clamp: don't cross centre
            if l_w > 0 then bb:paintRect(il, abs_y, l_w, 1, Blitbuffer.COLOR_BLACK) end
        end
        local ir = math.max(bx_left + (cx + nh) - w_diag_ot, bx_left + cx) -- clamp: don't start before centre
        if ir <= bx_right - ot then
            local r_w = bx_left + (cx + nh) - ir
            if r_w > 0 then bb:paintRect(ir, abs_y, r_w, 1, Blitbuffer.COLOR_BLACK) end
        end
    end
    bb:paintRect(bx_left,           tip_y, ot, 1, Blitbuffer.COLOR_BLACK)
    bb:paintRect(bx_right - ot + 1, tip_y, ot, 1, Blitbuffer.COLOR_BLACK)
end

-- ── half-chord helpers (module-level, used by paintProgressDots) ─────────────
-- hc_circle: standard circular chord (original helper).
local function hc(R, dy)
    return math.ceil(math.sqrt(math.max(0, R * R - dy * dy)) - 0.5)
end

-- hc_diamond: diamond (rotated square) — linear taper.
local function hc_diamond(R, dy)
    return math.max(0, R - math.abs(dy))
end

-- hc_rounded_square: square with circular corners of radius rc.
-- Outside the corner zone the half-chord is the full radius R.
local function hc_rounded_square(R, rc, dy)
    local ady = math.abs(dy)
    if ady <= R - rc then
        return R   -- flat sides
    else
        local rel = ady - (R - rc)
        return (R - rc) + math.max(0, math.ceil(math.sqrt(math.max(0, rc * rc - rel * rel)) - 0.5))
    end
end

-- hc_rounded_rect: axis-aligned rounded rectangle with independent half-extents.
-- Rx = horizontal half-width, Ry = vertical half-height, rc = corner radius.
-- Returns the horizontal half-chord at vertical offset dy, or -1 outside the shape.
local function hc_rounded_rect(Rx, Ry, rc, dy)
    local ady = math.abs(dy)
    if ady > Ry then return -1 end
    local rc_clamped = math.min(rc, Rx, Ry)
    if ady <= Ry - rc_clamped then
        return Rx   -- flat top/bottom side
    else
        local rel = ady - (Ry - rc_clamped)
        return (Rx - rc_clamped) + math.max(0, math.ceil(math.sqrt(math.max(0, rc_clamped * rc_clamped - rel * rel)) - 0.5))
    end
end

-- hc_rounded_diamond: diamond with rounded tips — circular arcs at top and
-- bottom, straight sides in the middle.  rc is tip-arc radius.
local function hc_rounded_diamond(R, rc, dy)
    local ady = math.abs(dy)
    if ady <= R - rc then
        -- straight diagonal sides: taper from R-rc at centre to 0 at tip zone
        return math.max(0, math.floor((R - rc) * (1 - ady / (R - rc)) + 0.5))
    else
        -- rounded tip arc
        local rel = ady - (R - rc)
        return math.max(0, math.ceil(math.sqrt(math.max(0, rc * rc - rel * rel)) - 0.5))
    end
end

-- ── progress-dot geometry cache ───────────────────────────────────────────────
local _dot_geom_cache = {}
local function getDotGeom(shape, r, ry, rc, outline_t, vertical,
                          long_r, short_r, flat_half, pill_flat_half)
    local key = table.concat({
        shape or "rounded_square", r, ry, rc, outline_t,
        vertical and 1 or 0, long_r or 0, short_r or 0,
        flat_half or 0, pill_flat_half or 0,
    }, ":")
    local cached = _dot_geom_cache[key]
    if cached then return cached end

    local ir  = math.max(0, r  - outline_t)
    local iry = math.max(0, ry - outline_t)
    local irc = math.max(0, rc - outline_t)
    local i_long_r, i_short_r, i_flat, i_flat_half = 0, 0, 0, 0
    if shape == "pill" then
        i_long_r  = math.max(0, long_r  - outline_t)
        i_short_r = math.max(0, short_r - outline_t)
        if vertical then
            i_flat = math.max(0, i_long_r - i_short_r)
        else
            i_flat_half = math.max(0, i_short_r - i_long_r)
        end
    end

    local hc_outer = {}
    local hc_inner = {}
    for dy = -ry, ry do
        local ady = math.abs(dy)
        local odx
        if shape == "rounded_square" then
            odx = hc_rounded_rect(r, ry, rc, dy)
        elseif shape == "diamond" then
            odx = hc_diamond(r, dy)
        elseif shape == "pill" then
            if vertical then
                if ady > long_r then
                    odx = -1
                elseif ady <= pill_flat_half then
                    odx = short_r
                else
                    local rel = ady - pill_flat_half
                    odx = math.ceil(math.sqrt(math.max(0, short_r * short_r - rel * rel)) - 0.5)
                end
            else
                if ady > long_r then
                    odx = -1
                else
                    local arc = math.ceil(math.sqrt(math.max(0, long_r * long_r - ady * ady)) - 0.5)
                    odx = flat_half + arc
                end
            end
        else
            odx = hc_rounded_rect(r, ry, rc, dy)
        end
        hc_outer[dy] = odx

        local idx
        if outline_t <= 0 then
            idx = -1
        elseif shape == "rounded_square" then
            idx = (ir > 0) and hc_rounded_rect(ir, iry, irc, dy) or -1
        elseif shape == "diamond" then
            idx = (ir > 0) and hc_diamond(ir, dy) or -1
        elseif shape == "pill" then
            if vertical then
                if i_long_r <= 0 or ady > i_long_r then
                    idx = -1
                elseif ady <= i_flat then
                    idx = i_short_r
                else
                    local rel = ady - i_flat
                    idx = math.ceil(math.sqrt(math.max(0, i_short_r * i_short_r - rel * rel)) - 0.5)
                end
            else
                if i_long_r <= 0 or ady > i_long_r then
                    idx = -1
                else
                    local arc = math.ceil(math.sqrt(math.max(0, i_long_r * i_long_r - ady * ady)) - 0.5)
                    idx = i_flat_half + arc
                end
            end
        else
            idx = (ir > 0) and hc_rounded_rect(ir, iry, irc, dy) or -1
        end
        hc_inner[dy] = idx
    end

    cached = { hc_outer = hc_outer, hc_inner = hc_inner, iry = iry }
    _dot_geom_cache[key] = cached
    return cached
end

-- ── dot layout helper (module-level to avoid per-call closure allocation) ─────
-- Returns the total pixel span of NUM_DOTS shapes of the given radius with
-- gap_pct spacing between them.
local function total_span(radius, num_dots, gap_pct)
    local g = math.max(1, math.floor(radius * gap_pct / 100))
    return num_dots * (2 * radius + g) - g
end

-- ── progress dots painter ─────────────────────────────────────────────────────
-- Draws NUM_DOTS shapes at the chosen edge of the cover.  Each shape fills
-- gradually as progress increases (left→right for horizontal positions,
-- bottom→top for vertical positions).
--
-- The 100% range is split into NUM_DOTS * SECTIONS_PER_DOT equal steps.
-- Fill level within a shape is a pixel x- (or y-) threshold.
-- A black outline is always drawn on top to frame each shape.
--
-- Supported shapes (progress_dots_shape setting):
--   "rounded_square"  – square with rounded corners
--   "diamond"         – rotated square (rhombus)
--   "pill"            – wide capsule / stadium shape
local function paintProgressDots(bb, cover_x, cover_y, cover_w, cover_h,
                                  percent, is_finished, ot)
    if not percent and not is_finished then return end
    ot = ot or 2

    -- hide dots for finished books when the setting is active
    if is_finished and get("progress_dots_hide_on_finished") then return end

    local NUM_DOTS         = get("progress_dots_num_dots")
    local SECTIONS_PER_DOT = get("progress_dots_sections")
    local dot_alpha        = get("progress_dots_alpha")
    local position         = get("progress_dots_position") or "bottom"
    local vertical         = (position == "left" or position == "right")
    local shape            = get("progress_dots_shape") or "rounded_square"

    -- dot radius: derived entirely from the two % margin settings.
    -- end_margin_pct reserves space at each end of the layout axis (the axis
    -- along which balls are arranged); the remaining span is shared equally
    -- among NUM_DOTS balls and their gaps, giving the maximum fitting radius.
    -- Always at least ot px so balls can never overlap the cover outline.
    local gap_pct          = get("progress_dots_gap_pct") or 100
    local end_margin_pct   = get("progress_dots_end_margin_pct") or 50
    local layout_dim       = vertical and cover_h or cover_w
    local end_margin_clamp = math.max(ot, math.floor(layout_dim * end_margin_pct / 1000))

    local avail = layout_dim - 2 * end_margin_clamp
    -- Closed-form initial estimate: span(r) ≈ r*(2*n + (n-1)*gf) where gf=gap_pct/100.
    -- This accounts for both shape diameter and inter-shape gaps in one division,
    -- starting much closer to the answer than the old floor(avail/n/2) estimate.
    -- At most two correction steps needed to land on the exact integer r.
    local gf    = gap_pct / 100
    local denom = 2 * NUM_DOTS + math.max(0, NUM_DOTS - 1) * gf
    local r = math.max(1, math.floor(avail / denom))
    -- Bump up if the floor undershot (rare but possible due to integer gap rounding).
    if total_span(r + 1, NUM_DOTS, gap_pct) <= avail then r = r + 1 end
    -- Trim back if the estimate overshot (can happen when gap_pct is very small).
    if r > 1 and total_span(r, NUM_DOTS, gap_pct) > avail then r = r - 1 end

    -- ── shape-specific geometry ───────────────────────────────────────────────
    -- For rectangle / bar shapes the vertical half-extent may differ from r.
    local rect_aspect = math.max(1, math.min(100, get("progress_dots_rect_aspect") or 50))
    local corner_pct  = math.max(0,  math.min(100, get("progress_dots_corner_pct")  or 35))
    local rc = math.floor(r * corner_pct / 100)  -- corner radius for rounded shapes (0 = square corners)

    -- ry: vertical half-extent of the bounding box for this shape
    local ry
    if shape == "rounded_square" then
        ry = math.max(1, math.floor(r * rect_aspect / 100))
    else
        ry = r
    end
    -- pill: width is r, height is ry=r but the rounded ends use rc = ry so it
    -- is always a true stadium.  We keep ry = r for pill (handled below).

    -- build the half-chord lookup tables for the chosen shape.
    -- hc_outer[dy] → outer half-width; hc_inner[dy] → inner half-width for the
    -- outline ring.  Both are precomputed here (once per paintProgressDots call)
    -- so per-ball scanline loops use integer array reads instead of closure calls.
    -- long_r / short_r / flat_half / pill_flat_half are used by the pill branches
    -- and must be in function scope so the table-build loop below can read them
    -- regardless of which shape branch was taken.
    local outline_t = get("progress_dots_outline") or 1
    local long_r, short_r, flat_half, pill_flat_half = 0, 0, 0, 0
    if shape == "rounded_square" then
        -- For vertical positions rotate 90° so the short axis is horizontal.
        if vertical then r, ry = ry, r end
    elseif shape == "diamond" then
        -- nothing extra needed
    elseif shape == "pill" then
        local pill_ry = math.max(1, math.floor(r * rect_aspect / 100))
        ry = pill_ry
        if vertical then
            r, ry = ry, r
            long_r          = ry
            short_r         = r
            pill_flat_half  = long_r - short_r
        else
            long_r      = ry
            short_r     = r
            flat_half   = math.max(0, short_r - long_r)
        end
    else
        -- fallback to rounded_square
    end

    local geom = getDotGeom(shape, r, ry, rc, outline_t, vertical,
                            long_r, short_r, flat_half, pill_flat_half)
    local hc_outer = geom.hc_outer
    local hc_inner = geom.hc_inner
    local iry      = geom.iry

    -- margin: distance from cover edge to shape centre.
    -- = ot + perp_r (minimum safe inset so the shape never clips the outline)
    --   + extra gap from margin_pct (% of the perpendicular cover dimension).
    -- Adding on top of the floor means margin_pct always produces visible
    -- breathing room regardless of shape size.
    local perp_dim   = vertical and cover_w or cover_h
    local margin_pct = get("progress_dots_margin_pct") or 30
    local perp_r     = vertical and r or ry
    local margin     = ot + perp_r + math.floor(perp_dim * margin_pct / 1000)
    -- end_margin: already computed above as end_margin_clamp (% of layout dim).
    -- Reuse that value here under the name end_margin for the placement code.
    local end_margin = end_margin_clamp
    -- gap and dot_step are based on the axis along which dots are laid out:
    --   horizontal layout → r  (horizontal half-extent)
    --   vertical layout   → ry (vertical half-extent, which is the long axis for rotated shapes)
    local layout_r = vertical and ry or r
    local gap      = math.max(1, math.floor(layout_r * gap_pct / 100))
    local dot_step = 2 * layout_r + gap

    local pct         = is_finished and 100 or (percent or 0)
    local total_steps = NUM_DOTS * SECTIONS_PER_DOT
    local steps_done  = pct * total_steps / 100

    local blend_val    = math.floor(dot_alpha * 255)
    local fully_opaque = (blend_val >= 255)

    -- resolve fill color once for all balls in this frame
    local fill_color = getDotsFillColor()
    local alpha_white, alpha_black, shared_tmp
    if not fully_opaque then
        alpha_white = Blitbuffer.ColorRGB32(255, 255, 255, blend_val)
        local fc_r = fill_color:getR()
        local fc_g = fill_color:getG()
        local fc_b = fill_color:getB()
        alpha_black = Blitbuffer.ColorRGB32(fc_r, fc_g, fc_b, blend_val)
    end

    -- ── paint one shape ───────────────────────────────────────────────────────
    -- cx, cy:      shape centre in bb coordinates
    -- fill_px:     how many pixels of diameter are filled (0=empty, 2r+1=full)
    -- fill_vertical: if true fill rises from bottom; if false fills from left
    -- paintScanlines and paintOutline use hc_outer / hc_inner (precomputed above)
    -- rather than closure calls, avoiding per-ball closure allocation.
    local function paintOneBall(cx, cy, fill_px, fill_vertical)
        -- bounding box uses r (x) and ry (y)
        local bx     = cx - r
        local by     = cy - ry
        local ball_w = 2 * r  + 1
        local ball_h = 2 * ry + 1

        -- fill boundary
        local fill_right, fill_top
        if fill_vertical then
            fill_top = cy + ry - fill_px + 1
        else
            fill_right = cx - r + fill_px - 1
        end

        -- ── helper: paint one scanline of the shape ───────────────────────────
        -- Uses hc_outer[dy] (precomputed table) instead of a hcFn closure.
        local function paintScanlines(target, ox, oy, white_col, black_col, is_blend)
            local paint = is_blend
                and function(tx, ty, w, col) target:blendRectRGB32(tx, ty, w, 1, col) end
                or  function(tx, ty, w, col) target:paintRect(tx, ty, w, 1, col) end

            for dy = -ry, ry do
                local dx = hc_outer[dy]
                if dx >= 0 then
                    local row   = cy + dy
                    local lx    = cx - dx
                    local rx2   = cx + dx
                    local trow  = row + oy
                    local tlx   = lx  + ox

                    if fill_px <= 0 then
                        -- entirely white
                        paint(tlx, trow, 2 * dx + 1, white_col)
                    elseif fill_vertical then
                        if row >= fill_top then
                            paint(tlx, trow, 2 * dx + 1, black_col)
                        else
                            paint(tlx, trow, 2 * dx + 1, white_col)
                        end
                    else
                        local fill_end_clamped = math.min(fill_right, rx2)
                        local run_b = math.max(0, fill_end_clamped - lx + 1)
                        local run_w = math.max(0, rx2 - lx + 1 - run_b)
                        if run_b > 0 then
                            paint(tlx, trow, run_b, black_col)
                        end
                        if run_w > 0 then
                            paint(tlx + run_b, trow, run_w, white_col)
                        end
                    end
                end
            end
        end

        -- ── helper: draw the outline of the shape onto target ─────────────────
        -- Uses hc_outer[dy] and hc_inner[dy] (precomputed tables).
        -- The hcInner closure dispatch block is entirely replaced — no allocation.
        local function paintOutline(target, ox, oy)
            if outline_t <= 0 then return end
            for dy = -ry, ry do
                local odx = hc_outer[dy]
                if odx >= 0 then
                    local row  = cy + dy
                    local trow = row + oy
                    local ady  = math.abs(dy)
                    if ady > iry then
                        -- entire row is outline (top/bottom caps)
                        target:paintRect(cx - odx + ox, trow, 2 * odx + 1, 1, Blitbuffer.COLOR_BLACK)
                    else
                        local idx = hc_inner[dy]
                        if idx < 0 then
                            target:paintRect(cx - odx + ox, trow, 2 * odx + 1, 1, Blitbuffer.COLOR_BLACK)
                        else
                            -- left ring segment
                            local ring = odx - idx
                            if ring > 0 then
                                target:paintRect(cx - odx + ox, trow, ring, 1, Blitbuffer.COLOR_BLACK)
                                target:paintRect(cx + idx + 1 + ox, trow, ring, 1, Blitbuffer.COLOR_BLACK)
                            end
                        end
                    end
                end
            end
        end

        if fully_opaque then
            -- 1. white base + fill
            paintScanlines(bb, 0, 0, Blitbuffer.COLOR_WHITE, fill_color, false)
            -- 2. outline on top
            paintOutline(bb, 0, 0)
        else
            -- alpha path: reuse one tmp buffer for the whole dot row/column
            if not shared_tmp then
                shared_tmp = Blitbuffer.new(ball_w, ball_h, bb:getType())
            end
            shared_tmp:blitFrom(bb, 0, 0, bx, by, ball_w, ball_h)
            -- blend fill into tmp (tmp-local coords: offset = -bx, -by)
            paintScanlines(shared_tmp, -bx, -by, alpha_white, alpha_black, true)
            -- blit blended result back to bb
            bb:blitFrom(shared_tmp, bx, by, 0, 0, ball_w, ball_h)
            -- outline at full opacity directly on bb
            paintOutline(bb, 0, 0)
        end
    end

    local appear_mode = get("progress_dots_appear_mode")

    -- ── lay out and paint all balls ───────────────────────────────────────────
    if not vertical then
        -- horizontal row (bottom or top)
        local total_w = NUM_DOTS * dot_step - gap
        -- start_x: left edge of the first ball's bounding box.
        -- With end_margin = 0 the row is centred; positive values push the row
        -- inward from both ends (the row stays centred but the usable span is
        -- narrowed so it never gets closer than end_margin px to the cover edge).
        local usable_w  = cover_w - 2 * end_margin
        local start_x   = cover_x + end_margin + math.floor((usable_w - total_w) / 2)
        local cy
        if position == "top" then
            cy = cover_y + margin
        else  -- bottom
            cy = cover_y + cover_h - 1 - margin
        end

        for i = 1, NUM_DOTS do
            local cx = start_x + (i - 1) * dot_step + r
            if appear_mode then
                -- ball 1: appears on open (book has been opened)
                -- ball N: appears when tier N is fully complete
                local ball_threshold = (i == 1) and 0 or i * SECTIONS_PER_DOT
                if steps_done >= ball_threshold then
                    paintOneBall(cx, cy, 2 * r + 1, false)  -- fully filled with fill color
                end
            else
                local ball_progress = math.max(0, math.min(SECTIONS_PER_DOT,
                    steps_done - (i - 1) * SECTIONS_PER_DOT))
                local fill_frac = ball_progress / SECTIONS_PER_DOT
                local fill_px   = math.floor(fill_frac * (2 * r) + 0.5)
                paintOneBall(cx, cy, fill_px, false)
            end
        end
    else
        -- vertical column (left or right), filling bottom-to-top
        -- balls are centred vertically within the inner area of the cover outline
        -- ball 1 is at the bottom, ball NUM_DOTS is at the top
        local inner_top    = cover_y + ot          -- first pixel inside top outline
        local inner_bottom = cover_y + cover_h - 1 - ot  -- last pixel inside bottom outline
        local inner_h      = inner_bottom - inner_top + 1

        local total_h = NUM_DOTS * dot_step - gap
        -- centre the stack vertically within the usable inner height.
        -- end_margin shrinks the usable zone equally from both ends, so the
        -- stack stays centred but never gets closer than end_margin px to the
        -- top or bottom cover edge.
        local inner_top_adj    = inner_top    + end_margin
        local inner_bottom_adj = inner_bottom - end_margin
        local usable_h = inner_bottom_adj - inner_top_adj + 1
        local stack_top_y = inner_top_adj + math.floor((usable_h - total_h) / 2)
        -- bottom ball centre: stack_top_y is the top of the top ball;
        -- last ball centre = stack_top_y + total_h - 1 - ry (the vertical half-extent)
        local bottom_ball_cy = stack_top_y + total_h - 1 - ry

        -- cx: ball centre inset by margin (already accounts for ot + perp_r via the margin calc above)
        local cx
        if position == "left" then
            cx = cover_x + margin
        else  -- right
            cx = cover_x + cover_w - 1 - margin
        end

        for i = 1, NUM_DOTS do
            -- i=1 → bottom ball, i=NUM_DOTS → top ball
            local cy = bottom_ball_cy - (i - 1) * dot_step
            if appear_mode then
                -- ball 1: appears on open (book has been opened)
                -- ball N: appears when tier N is fully complete
                local ball_threshold = (i == 1) and 0 or i * SECTIONS_PER_DOT
                if steps_done >= ball_threshold then
                    paintOneBall(cx, cy, 2 * ry + 1, true)  -- fully filled with fill color
                end
            else
                local ball_progress = math.max(0, math.min(SECTIONS_PER_DOT,
                    steps_done - (i - 1) * SECTIONS_PER_DOT))
                local fill_frac = ball_progress / SECTIONS_PER_DOT
                -- vertical fill spans 2*ry pixels (the shape's actual height)
                local fill_px   = math.floor(fill_frac * (2 * ry) + 0.5)
                paintOneBall(cx, cy, fill_px, true)
            end
        end
    end
    if shared_tmp then shared_tmp:free() end
end

-- ── badge font-size cache ──────────────────────────────────────────────────────
-- TextWidget creation inside a shrink loop is expensive.  For any given badge
-- ── rounded-end line cap chord cache ─────────────────────────────────────────
-- paintRoundedLine is called once per page-count line per cover per repaint.
-- With N items × up to 10 lines each, the sqrt loop inside the caps runs
-- thousands of times per frame — always for the same r = floor(page_thickness/2).
-- Pre-computing the half-chord table once per unique r and reusing it across all
-- calls drops the per-call cost to a plain integer array read.
-- Key: r (small positive integer); value: array indexed [-r..r] → half_chord.
local _cap_chord_cache = {}
local function getCapChords(r)
    if _cap_chord_cache[r] then return _cap_chord_cache[r] end
    local t = {}
    local rr = r * r
    for dr = -r, r do
        t[dr] = math.floor(math.sqrt(math.max(0, rr - dr * dr)) + 0.5)
    end
    _cap_chord_cache[r] = t
    return t
end

-- ── spine angle trim cache ───────────────────────────────────────────────────
local _spine_trim_cache = {}
local function getSpineTrims(strip_w, cut_h_top, cut_h_bot)
    local key = table.concat({ strip_w or 0, cut_h_top or 0, cut_h_bot or 0 }, ":")
    local cached = _spine_trim_cache[key]
    if cached then return cached.top, cached.bottom end

    local top = {}
    local bottom = {}
    for row = 0, math.max(0, (cut_h_top or 0) - 1) do
        local t = (cut_h_top - row) / cut_h_top
        top[row] = math.floor(t ^ 0.6 * strip_w)
    end
    for row = 0, math.max(0, (cut_h_bot or 0) - 1) do
        local t = (cut_h_bot - row) / cut_h_bot
        bottom[row] = math.floor((1 - (1 - t) ^ 0.6) * strip_w)
    end

    _spine_trim_cache[key] = { top = top, bottom = bottom }
    return top, bottom
end

local _page_line_layout_cache = {}
local function getPageLineLayout(strip_w, cut_h_top, num_lines, page_thick, page_gap, cover_w, len_pct)
    local key = table.concat({
        strip_w or 0, cut_h_top or 0, num_lines or 0,
        page_thick or 0, page_gap or 0, cover_w or 0, len_pct or 0,
    }, ":")
    local cached = _page_line_layout_cache[key]
    if cached then return cached end

    local top_trims = select(1, getSpineTrims(strip_w, cut_h_top, 0))
    local fixed_len = math.max(1, math.floor(cover_w * len_pct / 100))
    local line_step = page_thick + page_gap
    local lines = {}
    for i = 1, num_lines do
        local row_in_cut = cut_h_top - page_thick - page_gap - (i - 1) * line_step
        local trim = (row_in_cut >= 0 and row_in_cut < cut_h_top) and (top_trims[row_in_cut] or 0) or 0
        lines[i] = {
            trim = trim,
            len = (i == num_lines) and (fixed_len + 1) or fixed_len,
            by_off = page_thick + page_gap + (i - 1) * line_step,
        }
    end
    _page_line_layout_cache[key] = lines
    return lines
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
    -- filled-circle caps using precomputed half-chord table (no sqrt per scanline)
    local chords = getCapChords(r)
    for dr = -r, r do
        local half_chord = chords[dr]
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
-- Returns left/right/top/bottom whitespace offsets around the painted cover.
-- When aspect/stretch mode resamples the existing pixels, we need the full box,
-- not just left/top, otherwise the resampled source can include blank margins.
local function findCoverEdges(bb, cell_x, cell_w, cell_y, cell_h)
    local left_offset = 0
    local right_offset = 0
    local top_offset  = 0
    local bottom_offset = 0

    local sample_count = 5
    local scan_band    = math.floor(cell_h * 0.25)
    local step         = math.max(1, math.floor(scan_band / (sample_count - 1)))
    for i = 0, sample_count - 1 do
        local sy = cell_y + math.min(i * step, scan_band)
        for col = 0, cell_w - 1 do
            local c = bb:getPixel(cell_x + col, sy)
            if c and c:getR() < 250 then
                if col > left_offset then left_offset = col end
                break
            end
        end
    end

    for i = 0, sample_count - 1 do
        local sy = cell_y + math.min(i * step, scan_band)
        for col = cell_w - 1, 0, -1 do
            local c = bb:getPixel(cell_x + col, sy)
            if c and c:getR() < 250 then
                local off = cell_w - 1 - col
                if off > right_offset then right_offset = off end
                break
            end
        end
    end

    local mid_x = cell_x + math.floor(cell_w / 2)
    for row = 0, cell_h - 1 do
        local c = bb:getPixel(mid_x, cell_y + row)
        if c and c:getR() < 250 then top_offset = row; break end
    end

    for row = cell_h - 1, 0, -1 do
        local c = bb:getPixel(mid_x, cell_y + row)
        if c and c:getR() < 250 then
            bottom_offset = cell_h - 1 - row
            break
        end
    end

    -- Keep the box sane even if sampling misses an edge on noisy covers.
    if left_offset + right_offset >= cell_w then
        left_offset, right_offset = 0, 0
    end
    if top_offset + bottom_offset >= cell_h then
        top_offset, bottom_offset = 0, 0
    end

    return left_offset, right_offset, top_offset, bottom_offset
end

-- Trims whitespace *inside* an already-detected cover box.
-- This is stricter than findCoverEdges(): it samples across the whole source box
-- so aspect/stretch mode scales only the painted cover pixels, not any blank
-- side margins that KOReader may have left inside the box on first draw.
local function trimSourceBox(bb, x, y, w, h)
    if w <= 2 or h <= 2 then return x, y, w, h end

    local threshold = 250
    local row_samples = math.min(7, h)
    local col_samples = math.min(7, w)
    local function samplePos(count, span, idx)
        if count <= 1 then return math.floor(span / 2) end
        return math.floor(idx * (span - 1) / (count - 1))
    end

    local left, right = 0, 0
    local top, bottom = 0, 0

    for i = 0, row_samples - 1 do
        local sy = y + samplePos(row_samples, h, i)
        for col = 0, w - 1 do
            local c = bb:getPixel(x + col, sy)
            if c and c:getR() < threshold then
                if col > left then left = col end
                break
            end
        end
        for col = w - 1, 0, -1 do
            local c = bb:getPixel(x + col, sy)
            if c and c:getR() < threshold then
                local off = w - 1 - col
                if off > right then right = off end
                break
            end
        end
    end

    for i = 0, col_samples - 1 do
        local sx = x + samplePos(col_samples, w, i)
        for row = 0, h - 1 do
            local c = bb:getPixel(sx, y + row)
            if c and c:getR() < threshold then
                if row > top then top = row end
                break
            end
        end
        for row = h - 1, 0, -1 do
            local c = bb:getPixel(sx, y + row)
            if c and c:getR() < threshold then
                local off = h - 1 - row
                if off > bottom then bottom = off end
                break
            end
        end
    end

    if left + right >= w - 2 then left, right = 0, 0 end
    if top + bottom >= h - 2 then top, bottom = 0, 0 end

    local nx = x + left
    local ny = y + top
    local nw = math.max(1, w - left - right)
    local nh = math.max(1, h - top - bottom)
    return nx, ny, nw, nh
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
    if asp_enabled or scale_pct ~= 100 then
        cx, cy, cw, ch = trimSourceBox(bb, cx, cy, cw, ch)
    end

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

-- ── cover fill: progress overlay (bottom-to-top by default) ──────────────────
-- Paints a semi-transparent rectangle over the portion of the cover that has
-- already been read.
--   Default (cover_fill_top_to_bottom = false): fill rises from the bottom —
--     0% = no fill, 100% = full cover filled from bottom up.
--   Optional (cover_fill_top_to_bottom = true): fill descends from the top.
-- Respects the cover outline thickness (ot) so the overlay never overwrites
-- the border pixels.
local function paintCoverFill(bb, cover_x, cover_y, cover_w, cover_h,
                              percent, is_finished, ot)
    local pct = is_finished and 100 or (percent or 0)
    if pct <= 0 then return end
    if is_finished and get("cover_fill_hide_on_finished") then return end

    local alpha = get("cover_fill_alpha")
    local blend_val = math.floor(alpha * 255)
    if blend_val <= 0 then return end

    local fill_color = getCoverFillColor()
    local fc_r = fill_color:getR()
    local fc_g = fill_color:getG()
    local fc_b = fill_color:getB()
    local col = Blitbuffer.ColorRGB32(fc_r, fc_g, fc_b, blend_val)

    -- inner area: inset by outline thickness on all sides
    local inner_x = cover_x + ot
    local inner_y = cover_y + ot
    local inner_w = cover_w - 2 * ot
    local inner_h = cover_h - 2 * ot
    if inner_w <= 0 or inner_h <= 0 then return end

    local fill_h = math.floor(pct * inner_h / 100 + 0.5)
    fill_h = math.min(fill_h, inner_h)
    if fill_h <= 0 then return end

    if get("cover_fill_top_to_bottom") then
        -- fill descends from the top
        bb:blendRectRGB32(inner_x, inner_y, inner_w, fill_h, col)
    else
        -- fill rises from the bottom (default)
        local fill_y = inner_y + inner_h - fill_h
        bb:blendRectRGB32(inner_x, fill_y, inner_w, fill_h, col)
    end
end

-- ── core patch ────────────────────────────────────────────────────────────────
local function patchMosaicMenuItem(MosaicMenuItem)
    if MosaicMenuItem._vlabel_patched then return end
    MosaicMenuItem._vlabel_patched = true

    local orig_paintTo = MosaicMenuItem.paintTo

    MosaicMenuItem.paintTo = function(self, bb, x, y)
        -- ── snapshot all settings once per frame ──────────────────────────────
        -- get() is cheap but not free (table lookup + fallback check).  With
        -- N items on screen every paintTo call was repeating the same lookups
        -- for identical values.  Reading them once here and passing locals down
        -- costs nothing and removes redundant work for every item in the grid.
        local cfg_enabled               = get("enabled")
        local cfg_badge_enabled         = get("progress_badge_enabled")
        local cfg_dots_enabled          = get("progress_dots_enabled")
        local cfg_page_thickness        = get("page_thickness")
        local cfg_cover_scale_pct       = get("cover_scale_pct")
        local cfg_font_face             = get("font_face")
        local cfg_font_bold             = get("font_bold")
        local cfg_font_size             = get("font_size")
        local cfg_alpha                 = get("alpha")
        local cfg_dark_mode             = get("dark_mode")
        local cfg_direction             = get("direction")
        local cfg_padding               = get("padding")
        local cfg_text_shear            = get("text_shear")
        local cfg_page_spacing          = get("page_spacing")
        local cfg_page_line_length_pct  = get("page_line_length_pct")
        local cfg_badge_show_percent    = get("progress_badge_show_percent")
        local cfg_badge_show_checkmark  = get("progress_badge_show_checkmark")
        local cfg_badge_alpha           = get("progress_badge_alpha")
        local cfg_badge_position        = get("progress_badge_position")
        local cfg_badge_shape           = get("progress_badge_shape")
        local cfg_cover_fill_enabled    = get("cover_fill_enabled")

        -- suppress KOReader's built-in progress bar; we draw our own badge instead
        -- Newer KOReader builds crash in progresswidget.lua if percent_finished is nil
        -- but last_percent is a number (attempt to compare number with nil).
        -- Fix: save/restore both fields and use 0 (not nil) as the suppression value
        -- so ProgressWidget receives a valid number and skips rendering a zero bar.
        local saved_pct  = self.percent_finished
        local saved_last = self.last_percent
        if saved_pct ~= nil then
            self.percent_finished = 0
            self.last_percent     = 0
        end

        -- Suppress the KOReader dog-ear ("been opened" corner indicator).
        -- Save and nil every field name KOReader has ever used for this across
        -- versions; restore them all after orig_paintTo so nothing else breaks.
        local saved_been_opened  = self.been_opened
        local saved_file_status  = self.file_status
        local saved_read_status  = self.read_status
        if (cfg_badge_enabled or cfg_dots_enabled or cfg_cover_fill_enabled) and not self.is_directory then
            self.been_opened = nil
            self.file_status = nil
            self.read_status = nil
        end

        orig_paintTo(self, bb, x, y)

        self.percent_finished = saved_pct
        self.last_percent     = saved_last
        self.been_opened      = saved_been_opened
        self.file_status      = saved_file_status
        self.read_status      = saved_read_status

        if self.is_directory then return end

        local item_w = self.dimen and self.dimen.w or self.width  or 0
        local item_h = self.dimen and self.dimen.h or self.height or 0
        if item_w == 0 or item_h == 0 then return end

        local filepath = self.filepath or self.text
        local cached = getItemCached(filepath, item_w, item_h)

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
            -- When we are going to resample cover pixels (aspect-ratio/stretch or
            -- non-100% scale), the source box must match the pixels KOReader has
            -- already painted on screen. A BIM-derived box can be geometrically
            -- plausible but still include surrounding whitespace, which then gets
            -- stretched into visible bars on first open.
            local force_pixel_scan = get("aspect_enabled") or cfg_cover_scale_pct ~= 100

            -- ── Try BIM dimensions first ──────────────────────────────────────
            -- BIM data is exact and comes from a cached SQLite row (or an
            -- in-memory hit from _bim_dims_cache).  When it succeeds we skip
            -- findCoverEdges entirely — that scan walks up to 25% of the cell
            -- rows pixel-by-pixel and is the costliest part of the slow path.
            --
            -- _bim_dims_cache values:
            --   {cw,ch,nb_pages,title,authors,series,series_index}
            --                   → BIM hit (all fields stored in one query)
            --   false           → BIM miss (already queried, no data); use scan
            --   nil             → not yet tried; query BIM now
            local bim_cw_raw, bim_ch_raw
            local bim_bookinfo_cached  -- holds the cache entry for getLabelText below
            local cached_bim = ensureBIMCache(filepath)
            if cached_bim then
                -- in-memory hit: all fields already stored
                bim_cw_raw = cached_bim.cw
                bim_ch_raw = cached_bim.ch
                bim_bookinfo_cached = cached_bim
            end
            -- cached_bim == false → confirmed miss, bim_cw_raw/bim_ch_raw stay nil

            local bim_used = false
            if not force_pixel_scan and bim_cw_raw and bim_ch_raw then
                local scale  = math.min(item_w / bim_cw_raw, item_h / bim_ch_raw)
                local bim_cw = math.floor(bim_cw_raw * scale)
                local bim_ch = math.floor(bim_ch_raw * scale)
                if bim_cw > 4 and bim_ch > 4 then
                    cover_x  = x + math.floor((item_w - bim_cw) / 2)
                    cover_y  = y + math.floor((item_h - bim_ch) / 2)
                    cover_w  = bim_cw
                    cover_h  = bim_ch
                    bim_used = true
                end
            end

            if not bim_used then
                -- Either BIM had no usable data, or we explicitly need the exact
                -- painted-pixel box for a stretch/scale transform.
                local left_off, right_off, top_off, bottom_off = findCoverEdges(bb, x, item_w, y, item_h)
                cover_y = y + top_off
                cover_h = item_h - top_off - bottom_off
                cover_x = x + left_off
                cover_w = item_w - left_off - right_off
            end

            name      = getLabelText(self, bim_bookinfo_cached)
            num_lines = getNumLines(filepath)

            -- store offsets (not absolute coords) so cache is position-independent
            setItemCached(filepath, item_w, item_h, {
                left_off  = cover_x - x,
                top_off   = cover_y - y,
                cover_w   = cover_w,
                cover_h   = cover_h,
                name      = name,
                num_lines = num_lines,
            })
        end

        -- ── cover shape: runs regardless of spine-label enabled state ─────────
        -- strip_w is computed early so applyCoverTransform can reserve that space
        -- on the left before sizing the cover — prevents right-edge clipping.
        local strip_w    = cfg_enabled and getStripW(cover_w) or 0
        local left_reserve = strip_w > 0 and (strip_w + 1) or 0
        if cover_w > 0 and cover_h > 0 then
            cover_x, cover_y, cover_w, cover_h = applyCoverTransform(
                bb, x, y, item_w, item_h, cover_x, cover_y, cover_w, cover_h, left_reserve)
        end

        -- ── replace KOReader's 1px outline with our own (page_thickness wide) ──
        -- Always runs: covers 100% scale, aspect ratio changes, and reduced scale.
        -- All four sides are drawn: top, bottom, right (with rounded corners), and left.
        -- cover_x/y/w/h boundary includes KOReader's 1px outline pixel, so we
        -- draw our outline overlapping inward from that boundary — no gap.
        if cover_w > 0 and cover_h > 0 then
            local ot = cfg_page_thickness
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
            -- left bar: x = cover_x .. cover_x+ot-1, full height (square corners, spine sits here)
            bb:paintRect(cover_x, cover_y, ot, cover_h, Blitbuffer.COLOR_BLACK)

            -- Rounded corners: for each dy 0..r, paint the arc ring row.
            -- dy=0 is the centre row (horizontal tangent), dy=r is the top/bottom tangent row.
            local arc_tbl = getArcTable(r, r_inner)
            for dy = 0, r do
                local pair     = arc_tbl[dy]
                local outer_dx = pair[1]
                local inner_dx = pair[2]

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

        -- ── spine label: gated by main enabled flag ───────────────────────────
        -- Runs BEFORE progress dots so the spine samples clean cover pixels;
        -- dots painted after will appear on top of the spine, not baked into it.
        if cfg_enabled and cover_w > 0 and cover_h > 0 and name and name ~= "" then
            -- strip_w already computed above; fetch remaining per-frame locals
            local pad   = cfg_padding
            local fs    = cfg_font_size
            local alpha = cfg_alpha

            -- label sits flush against cover left edge; no overlap guaranteed by applyCoverTransform
            local label_x = math.max(x, cover_x - strip_w)

            -- angle cut depths (defined early so l_total can reference cut_h_top)
            local cut_h_bot = math.floor(strip_w * 0.5774)  -- tan(30°)

            -- dynamic line count based on page count
            local page_thick = cfg_page_thickness
            local page_gap   = cfg_page_spacing
            local line_step  = page_thick + page_gap
            local l_total    = num_lines * line_step
            local label_y    = cover_y - l_total
            local scale_pct  = cfg_cover_scale_pct
            local label_h    = cover_h + l_total + (scale_pct < 100 and 1 or 0) - 1

            -- top angle always spans exactly l_total so right corner anchors to cover_y
            local cut_h_top  = l_total

            -- text max_width excludes the angled cut areas so text stays within visible box
            local text_max_w = label_h - cut_h_top - cut_h_bot - 2 * pad
            local top_trims, bottom_trims = getSpineTrims(strip_w, cut_h_top, cut_h_bot)

            local spine_render = getSpineRenderCached(filepath, item_w, item_h)
            if not spine_render then
                -- Only cache the spine render when we know the real cover pixels
                -- are present (BIM has decoded the cover and stored its dims).
                -- If BIM dims are absent we still BUILD and DRAW the spine so it
                -- is visible on first open, but we do NOT store it in the cache.
                -- That way the next repaint (after KOReader decodes the real cover
                -- and BIM writes its dims) will enter this branch again and build
                -- a correct spine from the real cover pixels.
                local bim_entry = _bim_dims_cache[filepath]
                local cover_is_real = bim_entry and bim_entry.cw and bim_entry.ch

                if cover_w <= 8 or cover_h <= 8 then
                    goto spine_render_done
                end

                -- resolve font file from module-level map
                local face_entry = FONT_MAP[cfg_font_face] or FONT_MAP["NotoSerif"]
                local font_file  = cfg_font_bold and face_entry.bold or face_entry.regular

                -- build label widget sized to extended height
                local text_widget = TextWidget:new{
                    text                  = name,
                    face                  = getFaceCached(font_file, fs),
                    fgcolor               = Blitbuffer.COLOR_WHITE,
                    max_width             = math.max(1, text_max_w),
                    truncate_with_ellipsis = false,
                }
                -- rotate and blit back with angled top/bottom ends
                local angle   = (cfg_direction == "down") and 270 or 90

                -- sample the full cover strip (cover_h tall) then scale-stretch to label_h
                local tmp = Blitbuffer.new(label_h, strip_w, bb:getType())
                local src = Blitbuffer.new(strip_w, cover_h, bb:getType())
                src:blitFrom(bb, 0, 0, cover_x, cover_y, strip_w, cover_h)
                -- stretch src (strip_w x cover_h) -> stretched (strip_w x label_h)
                local stretched = src:scale(strip_w, label_h)
                src:free()
                -- rotate cover image with opposite angle so it cancels the final rotatedCopy,
                -- leaving the background upright while text (painted after) gets rotated once.
                local img_angle = (angle == 90) and 270 or 90
                local src_rot = stretched:rotatedCopy(img_angle)
                stretched:free()
                tmp:blitFrom(src_rot, 0, 0, 0, 0, label_h, strip_w)
                src_rot:free()

                -- blend bg color at alpha opacity onto cover pixels
                local dark_mode = cfg_dark_mode
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
                local shear = -(cfg_text_shear / 100)
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

                spine_render = {
                    rotated = tmp:rotatedCopy(angle),
                }
                tmp:free()
                -- Only persist the render when built from real cover pixels.
                -- When cover_is_real is false we still draw this frame's spine
                -- but leave the cache empty so the next repaint rebuilds from
                -- the actual decoded cover.
                if cover_is_real then
                    setSpineRenderCached(filepath, item_w, item_h, spine_render)
                end
            end
            ::spine_render_done::

            -- save background strip before we draw (so we can restore corners)
            local bg = getSpineBgScratch(strip_w, label_h, bb:getType())
            bg:blitFrom(bb, 0, 0, label_x, label_y, strip_w, label_h)

            -- blit the full rotated rectangle
            if spine_render then
                bb:blitFrom(spine_render.rotated, label_x, label_y, 0, 0, strip_w, label_h)
            end

            if spine_render then
            for row = 0, math.max(cut_h_top, cut_h_bot) - 1 do
                local brow = label_h - (scale_pct < 100 and 0 or 1) - row
                if row < cut_h_top then
                    local trim = top_trims[row] or 0
                    if trim > 0 then
                        bb:blitFrom(bg, label_x + strip_w - trim, label_y + row, strip_w - trim, row, trim, 1)
                    end
                end
                if row < cut_h_bot then
                    local trim = bottom_trims[row] or 0
                    if trim > 0 then
                        bb:paintRect(label_x, label_y + brow, trim, 1, Blitbuffer.COLOR_WHITE)
                    end
                end
            end

            -- draw lines above cover: all lines same length, anchored at spine angle edge
            do
                local color    = getLineColor()
                local len_pct  = cfg_page_line_length_pct
                local line_layout = getPageLineLayout(strip_w, cut_h_top, num_lines,
                    page_thick, page_gap, cover_w, len_pct)

                for i = 1, num_lines do
                    local layout = line_layout[i]
                    local by = cover_y - layout.by_off
                    local line_start = label_x + strip_w - layout.trim
                    local this_len = layout.len
                    local draw_len = math.min(this_len, cover_x + cover_w - line_start)
                    local line_color = (i == num_lines) and Blitbuffer.COLOR_GRAY_2 or color
                    if draw_len > 0 then
                        paintRoundedLine(bb, line_start, by, draw_len, page_thick, line_color)
                    end
                end
            end
            end -- if spine_render
        end

        -- ── progress badge: rounded-rect corner label ────────────────────────
        -- Runs after the outline. Pass the same corner radius so the badge fill
        -- can clip itself to avoid overwriting the outline's rounded-corner arc.
        -- Resolve progress and outline thickness once; share between badge and dots.
        local badge_enabled = cfg_badge_enabled
        local dots_enabled  = cfg_dots_enabled
        local fill_enabled  = cfg_cover_fill_enabled
        if (badge_enabled or dots_enabled or fill_enabled) and cover_w > 0 and cover_h > 0 then
            local prog_pct, prog_done = getReadingProgress(filepath)
            local shared_ot = cfg_page_thickness
            -- ── cover fill: drawn first so badges/dots appear on top ──────────
            if fill_enabled then
                paintCoverFill(bb, cover_x, cover_y, cover_w, cover_h,
                               prog_pct, prog_done, shared_ot)
            end
            if badge_enabled then
                -- Apply show_percent / show_checkmark filters
                local show_pct   = cfg_badge_show_percent
                local show_check = cfg_badge_show_checkmark
                local badge_pct  = show_pct   and prog_pct  or nil
                local badge_done = show_check and prog_done or false
                -- recompute outline corner radius (same formula as the outline block above)
                local badge_r = math.max(shared_ot,
                    math.min(shared_ot * 4, math.floor(math.min(cover_w, cover_h) / 4)))
                if cfg_badge_shape == "pentagon" then
                    paintProgressBadgePentagon(bb, filepath, cover_x, cover_y, cover_w, cover_h,
                                               badge_pct, badge_done, shared_ot,
                                               cfg_badge_alpha,
                                               getBadgeBgColor(),
                                               getBadgeCheckColor())
                elseif cfg_badge_shape == "w_shape" then
                    paintProgressBadgeW(bb, filepath, cover_x, cover_y, cover_w, cover_h,
                                        badge_pct, badge_done, shared_ot,
                                        cfg_badge_alpha,
                                        getBadgeBgColor(),
                                        getBadgeCheckColor())
                else
                    paintProgressBadge(bb, filepath, cover_x, cover_y, cover_w, cover_h,
                                       badge_pct, badge_done, shared_ot, badge_r,
                                       cfg_badge_alpha,
                                       cfg_badge_position,
                                       getBadgeBgColor(),
                                       getBadgeCheckColor())
                end
            end
            -- ── progress dots ─────────────────────────────────────────────────
            -- Drawn last so they always appear on top of the spine (not sampled into it).
            if dots_enabled then
                paintProgressDots(bb, cover_x, cover_y, cover_w, cover_h,
                                  prog_pct, prog_done, shared_ot)
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
                -- ── progress indicators submenu ────────────────────────────
                {
                    text = "Progress indicators",
                    sub_item_table_func = function()
                        local SpinWidget = require("ui/widget/spinwidget")
                        local UIManager  = require("ui/uimanager")
                        local function refreshProgress(tmi)
                            _docinfo_cache = {}
                            local fc = require("ui/widget/filechooser")
                            if fc.instance then fc.instance:updateItems() end
                            if tmi then tmi:updateItems() end
                        end
                        return {
                            -- ── badges submenu ─────────────────────────────
                            {
                                text = "Badges",
                                sub_item_table_func = function()
                                return {
                            -- ── progress badge toggle ───────────────────────
                            {
                                text_func = function()
                                    return "Progress badge"
                                end,
                                checked_func = function() return get("progress_badge_enabled") end,
                                callback = function(tmi)
                                    set("progress_badge_enabled", not get("progress_badge_enabled"))
                                    refreshProgress(tmi)
                                end,
                            },
                            -- ── badge show % progress ───────────────────────
                            {
                                text_func = function()
                                    return "Badge: show % progress"
                                end,
                                checked_func = function() return get("progress_badge_show_percent") end,
                                enabled_func = function() return get("progress_badge_enabled") end,
                                callback = function(tmi)
                                    set("progress_badge_show_percent", not get("progress_badge_show_percent"))
                                    refreshProgress(tmi)
                                end,
                            },
                            -- ── badge show checkmark ────────────────────────
                            {
                                text_func = function()
                                    return "Badge: show checkmark (finished books)"
                                end,
                                checked_func = function() return get("progress_badge_show_checkmark") end,
                                enabled_func = function() return get("progress_badge_enabled") end,
                                callback = function(tmi)
                                    set("progress_badge_show_checkmark", not get("progress_badge_show_checkmark"))
                                    refreshProgress(tmi)
                                end,
                            },
                            -- ── badge shape ─────────────────────────────────
                            {
                                text_func = function()
                                    local s = get("progress_badge_shape") or "rectangle"
                                    local labels = {
                                        rectangle = "Badge shape: Rectangle (half curved)",
                                        pentagon  = "Badge shape: Bookmark",
                                        w_shape   = "Badge shape: Bookmark (double pointed)",
                                    }
                                    return labels[s] or ("Badge shape: " .. s)
                                end,
                                enabled_func = function() return get("progress_badge_enabled") end,
                                sub_item_table = {
                                    {
                                        text = "Rectangle (half curved)",
                                        checked_func = function()
                                            return (get("progress_badge_shape") or "rectangle") == "rectangle"
                                        end,
                                        callback = function()
                                            set("progress_badge_shape", "rectangle")
                                            _docinfo_cache = {}
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                        end,
                                    },
                                    {
                                        text = "Bookmark",
                                        checked_func = function()
                                            return get("progress_badge_shape") == "pentagon"
                                        end,
                                        callback = function()
                                            set("progress_badge_shape", "pentagon")
                                            _docinfo_cache = {}
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                        end,
                                    },
                                    {
                                        text = "Bookmark (double pointed)",
                                        checked_func = function()
                                            return get("progress_badge_shape") == "w_shape"
                                        end,
                                        callback = function()
                                            set("progress_badge_shape", "w_shape")
                                            _docinfo_cache = {}
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                        end,
                                    },
                                },
                            },
                            -- ── pentagon badge width ────────────────────────
                            {
                                text_func = function()
                                    return ("Badge width: %.1f%% of cover width"):format(get("pentagon_badge_w_pct") / 10)
                                end,
                                enabled_func = function()
                                    local s = get("progress_badge_shape") or "rectangle"
                                    return get("progress_badge_enabled")
                                       and (s == "rectangle" or s == "pentagon" or s == "w_shape")
                                end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    local SpinWidget = require("ui/widget/spinwidget")
                                    local UIManager  = require("ui/uimanager")
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Badge width (% of cover width)",
                                        value               = get("pentagon_badge_w_pct"),
                                        value_min           = 50,    -- 5.0%
                                        value_max           = 600,   -- 60.0%
                                        value_step          = 5,     -- 0.5% step
                                        default_value       = DEFAULTS.pentagon_badge_w_pct,
                                        keep_shown_on_apply = true,
                                        value_text_func     = function(v)
                                            return string.format("%.1f%%", v / 10)
                                        end,
                                        callback = function(spin)
                                            set("pentagon_badge_w_pct", spin.value)
                                            _docinfo_cache = {}
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                            if tmi then tmi:updateItems() end
                                        end,
                                    })
                                end,
                            },
                            -- ── pentagon badge height ────────────────────────
                            {
                                text_func = function()
                                    return ("Badge height: %.1f%% of cover min-dim"):format(get("pentagon_badge_h_pct") / 10)
                                end,
                                enabled_func = function()
                                    local s = get("progress_badge_shape") or "rectangle"
                                    return get("progress_badge_enabled")
                                       and (s == "rectangle" or s == "pentagon" or s == "w_shape")
                                end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    local SpinWidget = require("ui/widget/spinwidget")
                                    local UIManager  = require("ui/uimanager")
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Badge height (% of cover min dimension)",
                                        value               = get("pentagon_badge_h_pct"),
                                        value_min           = 50,    -- 5.0%
                                        value_max           = 600,   -- 60.0%
                                        value_step          = 5,     -- 0.5% step
                                        default_value       = DEFAULTS.pentagon_badge_h_pct,
                                        keep_shown_on_apply = true,
                                        value_text_func     = function(v)
                                            return string.format("%.1f%%", v / 10)
                                        end,
                                        callback = function(spin)
                                            set("pentagon_badge_h_pct", spin.value)
                                            _docinfo_cache = {}
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                            if tmi then tmi:updateItems() end
                                        end,
                                    })
                                end,
                            },
                            -- ── pentagon rect ratio ──────────────────────────
                            {
                                text_func = function()
                                    return ("Badge body: %.1f%% of total height"):format(get("pentagon_badge_rect_pct") / 10)
                                end,
                                enabled_func = function()
                                    local s = get("progress_badge_shape") or "rectangle"
                                    return get("progress_badge_enabled")
                                       and (s == "rectangle" or s == "pentagon" or s == "w_shape")
                                end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    local SpinWidget = require("ui/widget/spinwidget")
                                    local UIManager  = require("ui/uimanager")
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Badge body height (% of total height)",
                                        value               = get("pentagon_badge_rect_pct"),
                                        value_min           = 100,   -- 10.0% — always some triangle
                                        value_max           = 950,   -- 95.0% — always some triangle
                                        value_step          = 5,     -- 0.5% step
                                        default_value       = DEFAULTS.pentagon_badge_rect_pct,
                                        keep_shown_on_apply = true,
                                        value_text_func     = function(v)
                                            return string.format("%.1f%%", v / 10)
                                        end,
                                        callback = function(spin)
                                            set("pentagon_badge_rect_pct", spin.value)
                                            _docinfo_cache = {}
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                            if tmi then tmi:updateItems() end
                                        end,
                                    })
                                end,
                            },
                            -- ── pentagon right margin ────────────────────────
                            {
                                text_func = function()
                                    return ("Bookmark right margin: %.1f%% of cover width"):format(get("pentagon_badge_right_margin_pct") / 10)
                                end,
                                enabled_func = function()
                                    return get("progress_badge_enabled")
                                       and (get("progress_badge_shape") == "pentagon" or get("progress_badge_shape") == "w_shape")
                                end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    local SpinWidget = require("ui/widget/spinwidget")
                                    local UIManager  = require("ui/uimanager")
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Bookmark right margin (% of cover width)",
                                        value               = get("pentagon_badge_right_margin_pct"),
                                        value_min           = 0,
                                        value_max           = 1000,  -- 100.0%
                                        value_step          = 5,     -- 0.5% step
                                        default_value       = DEFAULTS.pentagon_badge_right_margin_pct,
                                        keep_shown_on_apply = true,
                                        value_text_func     = function(v)
                                            return string.format("%.1f%%", v / 10)
                                        end,
                                        callback = function(spin)
                                            set("pentagon_badge_right_margin_pct", spin.value)
                                            _docinfo_cache = {}
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                            if tmi then tmi:updateItems() end
                                        end,
                                    })
                                end,
                            },
                            -- ── Pentagon/W badge: fill mode toggle ───────────
                            {
                                text_func = function()
                                    local on = get("pentagon_badge_fill_mode")
                                    return "Bookmark fill mode: " .. (on and "On (top-to-bottom fill)" or "Off (show % text)")
                                end,
                                enabled_func = function()
                                    local s = get("progress_badge_shape") or "rectangle"
                                    return get("progress_badge_enabled")
                                       and (s == "pentagon" or s == "w_shape")
                                end,
                                checked_func = function()
                                    return get("pentagon_badge_fill_mode") == true
                                end,
                                callback = function()
                                    set("pentagon_badge_fill_mode", not get("pentagon_badge_fill_mode"))
                                    _docinfo_cache = {}
                                    local fc = require("ui/widget/filechooser")
                                    if fc.instance then fc.instance:updateItems() end
                                end,
                            },
                            -- ── Pentagon/W badge: fill color ─────────────────
                            {
                                text_func = function()
                                    local key = get("pentagon_badge_fill_color") or "WHITE"
                                    for _, entry in ipairs(DOTS_FILL_COLOR_MAP) do
                                        if entry.key == key then
                                            return "Bookmark fill color: " .. entry.label:gsub("%s+%b()",""):gsub("%s+$","")
                                        end
                                    end
                                    return "Bookmark fill color: White"
                                end,
                                enabled_func = function()
                                    local s = get("progress_badge_shape") or "rectangle"
                                    return get("progress_badge_enabled")
                                       and (s == "pentagon" or s == "w_shape")
                                       and get("pentagon_badge_fill_mode") == true
                                end,
                                sub_item_table_func = function()
                                    local color_items = {}
                                    for _, entry in ipairs(DOTS_FILL_COLOR_MAP) do
                                        local ekey = entry.key
                                        table.insert(color_items, {
                                            text = entry.label,
                                            checked_func = function()
                                                return (get("pentagon_badge_fill_color") or "WHITE") == ekey
                                            end,
                                            callback = function()
                                                set("pentagon_badge_fill_color", ekey)
                                                _badge_fill_color_cache = nil
                                                _docinfo_cache = {}
                                                local fc = require("ui/widget/filechooser")
                                                if fc.instance then fc.instance:updateItems() end
                                            end,
                                        })
                                    end
                                    return color_items
                                end,
                            },
                            -- ── badge position ──────────────────────────────
                            {
                                text_func = function()
                                    local pos = get("progress_badge_position") or "bottom_right"
                                    local labels = {
                                        bottom_right = "Badge position: Bottom-right",
                                        top_right    = "Badge position: Top-right",
                                    }
                                    return labels[pos] or ("Badge position: " .. pos)
                                end,
                                enabled_func = function()
                                    local s = get("progress_badge_shape") or "rectangle"
                                    return get("progress_badge_enabled")
                                       and s ~= "pentagon" and s ~= "w_shape"
                                end,
                                sub_item_table = {
                                    {
                                        text = "Bottom-right",
                                        checked_func = function()
                                            return (get("progress_badge_position") or "bottom_right") == "bottom_right"
                                        end,
                                        callback = function()
                                            set("progress_badge_position", "bottom_right")
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                        end,
                                    },
                                    {
                                        text = "Top-right",
                                        checked_func = function()
                                            return get("progress_badge_position") == "top_right"
                                        end,
                                        callback = function()
                                            set("progress_badge_position", "top_right")
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                        end,
                                    },
                                },
                            },
                            -- ── progress badge opacity ──────────────────────
                            {
                                text_func = function()
                                    local v = math.floor(get("progress_badge_alpha") * 100 + 0.5)
                                    if v == 100 then return "Badge opacity: 100% (fully opaque)"
                                    elseif v == 0 then return "Badge opacity: 0% (fully transparent)"
                                    else return ("Badge opacity: %d%%"):format(v) end
                                end,
                                enabled_func = function() return get("progress_badge_enabled") end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Badge opacity (0 = transparent, 100 = opaque)",
                                        value               = math.floor(get("progress_badge_alpha") * 100 + 0.5),
                                        value_min           = 0,
                                        value_max           = 100,
                                        value_step          = 5,
                                        default_value       = math.floor(DEFAULTS.progress_badge_alpha * 100 + 0.5),
                                        keep_shown_on_apply = true,
                                        value_text_func     = function(v) return v .. "%" end,
                                        callback = function(spin)
                                            set("progress_badge_alpha", spin.value / 100)
                                            refreshProgress(tmi)
                                        end,
                                    })
                                end,
                            },
                            -- ── badge background color ──────────────────────
                            {
                                text_func = function()
                                    local key = get("progress_badge_bg_color") or "BLACK"
                                    for _, entry in ipairs(DOTS_FILL_COLOR_MAP) do
                                        if entry.key == key then
                                            return "Badge bg color: " .. entry.label:gsub("%s+%b()",""):gsub("%s+$","")
                                        end
                                    end
                                    return "Badge bg color: Black"
                                end,
                                enabled_func = function() return get("progress_badge_enabled") end,
                                sub_item_table_func = function()
                                    local color_items = {}
                                    for _, entry in ipairs(DOTS_FILL_COLOR_MAP) do
                                        local ekey = entry.key
                                        table.insert(color_items, {
                                            text = entry.label,
                                            checked_func = function()
                                                return (get("progress_badge_bg_color") or "BLACK") == ekey
                                            end,
                                            callback = function()
                                                set("progress_badge_bg_color", ekey)
                                                _badge_bg_color_cache = nil
                                                _docinfo_cache = {}
                                                local fc = require("ui/widget/filechooser")
                                                if fc.instance then fc.instance:updateItems() end
                                            end,
                                        })
                                    end
                                    return color_items
                                end,
                            },
                            -- ── badge checkmark / text color ─────────────────
                            {
                                text_func = function()
                                    local key = get("progress_badge_check_color") or "WHITE"
                                    return "Badge text color: " .. (key == "BLACK" and "Black" or "White")
                                end,
                                enabled_func = function() return get("progress_badge_enabled") end,
                                sub_item_table = {
                                    {
                                        text = "White",
                                        checked_func = function()
                                            return (get("progress_badge_check_color") or "WHITE") == "WHITE"
                                        end,
                                        callback = function()
                                            set("progress_badge_check_color", "WHITE")
                                            _docinfo_cache = {}
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                        end,
                                    },
                                    {
                                        text = "Black",
                                        checked_func = function()
                                            return (get("progress_badge_check_color") or "WHITE") == "BLACK"
                                        end,
                                        callback = function()
                                            set("progress_badge_check_color", "BLACK")
                                            _docinfo_cache = {}
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                        end,
                                    },
                                },
                            },
                                } end,
                            },
                            -- ── bars submenu ────────────────────────────────
                            {
                                text = "Bars",
                                sub_item_table_func = function()
                                return {
                            -- ── balls of progress toggle ────────────────────
                            {
                                text_func = function()
                                    return "Bars of progress"
                                end,
                                checked_func = function() return get("progress_dots_enabled") end,
                                callback = function(tmi)
                                    set("progress_dots_enabled", not get("progress_dots_enabled"))
                                    refreshProgress(tmi)
                                end,
                            },
                            -- ── hide balls on finished books ─────────────────
                            {
                                text_func = function()
                                    return "Bars: hide on finished books"
                                end,
                                checked_func = function() return get("progress_dots_hide_on_finished") end,
                                enabled_func = function() return get("progress_dots_enabled") end,
                                callback = function(tmi)
                                    set("progress_dots_hide_on_finished", not get("progress_dots_hide_on_finished"))
                                    refreshProgress(tmi)
                                end,
                            },
                            -- ── appear mode toggle ───────────────────────────
                            {
                                text_func = function()
                                    return "Bars: appear mode (bars appear filled, one-by-one)"
                                end,
                                checked_func = function() return get("progress_dots_appear_mode") end,
                                enabled_func = function() return get("progress_dots_enabled") end,
                                callback = function(tmi)
                                    set("progress_dots_appear_mode", not get("progress_dots_appear_mode"))
                                    refreshProgress(tmi)
                                end,
                            },
                            -- ── shape ────────────────────────────────────────
                            {
                                text_func = function()
                                    local s = get("progress_dots_shape") or "rounded_square"
                                    local labels = {
                                        rounded_square = "Shape: Rounded square",
                                        diamond        = "Shape: Diamond",
                                        pill           = "Shape: Pill",
                                    }
                                    return labels[s] or ("Shape: " .. s)
                                end,
                                enabled_func = function() return get("progress_dots_enabled") end,
                                sub_item_table = (function()
                                    local shape_list = {
                                        { key = "rounded_square",  label = "Rounded square  (uses height % setting)" },
                                        { key = "diamond",         label = "Diamond  (rotated square)" },
                                        { key = "pill",            label = "Pill  (uses height % setting)" },
                                    }
                                    local items = {}
                                    for _, entry in ipairs(shape_list) do
                                        local ekey = entry.key
                                        table.insert(items, {
                                            text = entry.label,
                                            checked_func = function()
                                                return (get("progress_dots_shape") or "rounded_square") == ekey
                                            end,
                                            callback = function()
                                                set("progress_dots_shape", ekey)
                                                _docinfo_cache = {}
                                                local fc = require("ui/widget/filechooser")
                                                if fc.instance then fc.instance:updateItems() end
                                            end,
                                        })
                                    end
                                    return items
                                end)(),
                            },
                            -- ── height % (rectangle / pill / bar) ────────────
                            {
                                text_func = function()
                                    local s = get("progress_dots_shape") or "rounded_square"
                                    local v = get("progress_dots_rect_aspect") or 50
                                    if s == "pill" or s == "rounded_square" then
                                        return ("Shape height: %d%% of diameter"):format(v)
                                    else
                                        return "Shape height: (not used for current shape)"
                                    end
                                end,
                                enabled_func = function()
                                    local s = get("progress_dots_shape") or "rounded_square"
                                    return get("progress_dots_enabled") and
                                           (s == "pill" or s == "rounded_square")
                                end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    local SpinWidget = require("ui/widget/spinwidget")
                                    local UIManager  = require("ui/uimanager")
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Shape height as % of full diameter (1–100)",
                                        value               = get("progress_dots_rect_aspect") or 50,
                                        value_min           = 1,
                                        value_max           = 100,
                                        value_step          = 5,
                                        default_value       = DEFAULTS.progress_dots_rect_aspect,
                                        keep_shown_on_apply = true,
                                        value_text_func     = function(v) return v .. "%" end,
                                        callback = function(spin)
                                            set("progress_dots_rect_aspect", spin.value)
                                            refreshProgress(tmi)
                                        end,
                                    })
                                end,
                            },
                            -- ── corner radius % (rounded shapes) ─────────────
                            {
                                text_func = function()
                                    local s = get("progress_dots_shape") or "rounded_square"
                                    local v = get("progress_dots_corner_pct") or 35
                                    if s == "rounded_square" then
                                        return ("Corner radius: %d%% of r"):format(v)
                                    else
                                        return "Corner radius: (not used for current shape)"
                                    end
                                end,
                                enabled_func = function()
                                    local s = get("progress_dots_shape") or "rounded_square"
                                    return get("progress_dots_enabled") and
                                           (s == "rounded_square")
                                end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    local SpinWidget = require("ui/widget/spinwidget")
                                    local UIManager  = require("ui/uimanager")
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Corner/tip radius as % of half-size (5–50)",
                                        value               = get("progress_dots_corner_pct") or 35,
                                        value_min           = 0,
                                        value_max           = 100,
                                        value_step          = 5,
                                        default_value       = DEFAULTS.progress_dots_corner_pct,
                                        keep_shown_on_apply = true,
                                        value_text_func     = function(v) return v .. "%" end,
                                        callback = function(spin)
                                            set("progress_dots_corner_pct", spin.value)
                                            refreshProgress(tmi)
                                        end,
                                    })
                                end,
                            },
                            -- ── ball opacity ─────────────────────────────────
                            {
                                text_func = function()
                                    local v = math.floor(get("progress_dots_alpha") * 100 + 0.5)
                                    if v == 100 then return "Bar opacity: 100% (fully opaque)"
                                    elseif v == 0 then return "Bar opacity: 0% (fully transparent)"
                                    else return ("Bar opacity: %d%%"):format(v) end
                                end,
                                enabled_func = function() return get("progress_dots_enabled") end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Bar opacity (0 = transparent, 100 = opaque)",
                                        value               = math.floor(get("progress_dots_alpha") * 100 + 0.5),
                                        value_min           = 0,
                                        value_max           = 100,
                                        value_step          = 5,
                                        default_value       = math.floor(DEFAULTS.progress_dots_alpha * 100 + 0.5),
                                        keep_shown_on_apply = true,
                                        value_text_func     = function(v) return v .. "%" end,
                                        callback = function(spin)
                                            set("progress_dots_alpha", spin.value / 100)
                                            refreshProgress(tmi)
                                        end,
                                    })
                                end,
                            },
                            -- ── balls fill color ─────────────────────────────
                            {
                                text_func = function()
                                    local key = get("progress_dots_fill_color") or "BLACK"
                                    for _, entry in ipairs(DOTS_FILL_COLOR_MAP) do
                                        if entry.key == key then
                                            return "Bar fill color: " .. entry.label:gsub("%s+%b()",""):gsub("%s+$","")
                                        end
                                    end
                                    return "Bar fill color: Black"
                                end,
                                enabled_func = function() return get("progress_dots_enabled") end,
                                sub_item_table_func = function()
                                    local color_items = {}
                                    for _, entry in ipairs(DOTS_FILL_COLOR_MAP) do
                                        local ekey = entry.key
                                        table.insert(color_items, {
                                            text = entry.label,
                                            checked_func = function()
                                                return (get("progress_dots_fill_color") or "BLACK") == ekey
                                            end,
                                            callback = function()
                                                set("progress_dots_fill_color", ekey)
                                                _dots_fill_color_cache = nil
                                                _docinfo_cache = {}
                                                local fc = require("ui/widget/filechooser")
                                                if fc.instance then fc.instance:updateItems() end
                                            end,
                                        })
                                    end
                                    return color_items
                                end,
                            },
                            -- ── balls position ───────────────────────────────
                            {
                                text_func = function()
                                    local p = get("progress_dots_position") or "bottom"
                                    local labels = {
                                        bottom = "Position: bottom",
                                        top    = "Position: top",
                                        left   = "Position: left (vertical)",
                                        right  = "Position: right (vertical)",
                                    }
                                    return labels[p] or "Position: bottom"
                                end,
                                enabled_func = function() return get("progress_dots_enabled") end,
                                sub_item_table = {
                                    {
                                        text = "Bottom  (horizontal, fills left→right)",
                                        checked_func = function()
                                            return (get("progress_dots_position") or "bottom") == "bottom"
                                        end,
                                        callback = function()
                                            set("progress_dots_position", "bottom")
                                            _docinfo_cache = {}
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                        end,
                                    },
                                    {
                                        text = "Top  (horizontal, fills left→right)",
                                        checked_func = function()
                                            return get("progress_dots_position") == "top"
                                        end,
                                        callback = function()
                                            set("progress_dots_position", "top")
                                            _docinfo_cache = {}
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                        end,
                                    },
                                    {
                                        text = "Left  (vertical, fills bottom→top)",
                                        checked_func = function()
                                            return get("progress_dots_position") == "left"
                                        end,
                                        callback = function()
                                            set("progress_dots_position", "left")
                                            _docinfo_cache = {}
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                        end,
                                    },
                                    {
                                        text = "Right  (vertical, fills bottom→top)",
                                        checked_func = function()
                                            return get("progress_dots_position") == "right"
                                        end,
                                        callback = function()
                                            set("progress_dots_position", "right")
                                            _docinfo_cache = {}
                                            local fc = require("ui/widget/filechooser")
                                            if fc.instance then fc.instance:updateItems() end
                                        end,
                                    },
                                },
                            },
                            -- ── number of balls ─────────────────────────────
                            {
                                text_func = function()
                                    return ("Bars: %d bars"):format(get("progress_dots_num_dots"))
                                end,
                                enabled_func = function() return get("progress_dots_enabled") end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Number of balls",
                                        value               = get("progress_dots_num_dots"),
                                        value_min           = 1,
                                        value_max           = 40,
                                        value_step          = 1,
                                        default_value       = DEFAULTS.progress_dots_num_dots,
                                        keep_shown_on_apply = true,
                                        callback = function(spin)
                                            set("progress_dots_num_dots", spin.value)
                                            refreshProgress(tmi)
                                        end,
                                    })
                                end,
                            },
                            -- ── ball outline thickness ───────────────────────
                            {
                                text_func = function()
                                    local v = get("progress_dots_outline") or 1
                                    if v == 0 then
                                        return "Bar outline: off"
                                    end
                                    return ("Bar outline: %d px"):format(v)
                                end,
                                enabled_func = function() return get("progress_dots_enabled") end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    local SpinWidget = require("ui/widget/spinwidget")
                                    local UIManager  = require("ui/uimanager")
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Bar outline thickness (0 = no outline)",
                                        value               = get("progress_dots_outline") or 1,
                                        value_min           = 0,
                                        value_max           = 5,
                                        value_step          = 1,
                                        default_value       = DEFAULTS.progress_dots_outline,
                                        keep_shown_on_apply = true,
                                        value_text_func     = function(v)
                                            if v == 0 then return "off" end
                                            return v .. " px"
                                        end,
                                        callback = function(spin)
                                            set("progress_dots_outline", spin.value)
                                            refreshProgress(tmi)
                                        end,
                                    })
                                end,
                            },
                            -- ── gap between balls ────────────────────────────
                            {
                                text_func = function()
                                    local v = get("progress_dots_gap_pct") or 100
                                    return ("Bar gap: %d%% of radius"):format(v)
                                end,
                                enabled_func = function() return get("progress_dots_enabled") end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    local SpinWidget = require("ui/widget/spinwidget")
                                    local UIManager  = require("ui/uimanager")
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Gap between balls (% of ball radius)",
                                        value               = get("progress_dots_gap_pct") or 100,
                                        value_min           = 0,
                                        value_max           = 300,
                                        value_step          = 10,
                                        default_value       = DEFAULTS.progress_dots_gap_pct,
                                        keep_shown_on_apply = true,
                                        value_text_func     = function(v) return v .. "%" end,
                                        callback = function(spin)
                                            set("progress_dots_gap_pct", spin.value)
                                            refreshProgress(tmi)
                                        end,
                                    })
                                end,
                            },
                            -- ── ball margin (perpendicular, % of cover) ──────
                            -- SpinWidget only handles integers, so we store real % values
                            -- (e.g. 3.0, 0.5) stored ×10 as integers; spinner step of 5 = 0.5% each.
                            {
                                text_func = function()
                                    local v = get("progress_dots_margin_pct") or 30
                                    return ("Bar margin: %.1f%% of cover depth"):format(v / 10)
                                end,
                                enabled_func = function() return get("progress_dots_enabled") end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    local cur = get("progress_dots_margin_pct") or 30
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Gap between ball edge and cover outline (% of cover depth)  [5 steps = 0.5%]",
                                        value               = cur,
                                        value_min           = 0,
                                        value_max           = 600,
                                        value_step          = 5,
                                        default_value       = DEFAULTS.progress_dots_margin_pct,
                                        keep_shown_on_apply = true,
                                        value_text_func     = function(v) return ("%.1f%%"):format(v / 10) end,
                                        callback = function(spin)
                                            set("progress_dots_margin_pct", spin.value)
                                            refreshProgress(tmi)
                                        end,
                                    })
                                end,
                            },
                            -- ── ball ends margins (layout axis, % of cover) ────
                            {
                                text_func = function()
                                    local v = get("progress_dots_end_margin_pct") or 50
                                    return ("Bar ends margins: %.1f%% of cover width"):format(v / 10)
                                end,
                                enabled_func = function() return get("progress_dots_enabled") end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    local cur = get("progress_dots_end_margin_pct") or 50
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Clearance at each end of the ball row / column — ends margins (% of cover width)  [5 steps = 0.5%]",
                                        value               = cur,
                                        value_min           = 0,
                                        value_max           = 600,
                                        value_step          = 5,
                                        default_value       = DEFAULTS.progress_dots_end_margin_pct,
                                        keep_shown_on_apply = true,
                                        value_text_func     = function(v) return ("%.1f%%"):format(v / 10) end,
                                        callback = function(spin)
                                            set("progress_dots_end_margin_pct", spin.value)
                                            refreshProgress(tmi)
                                        end,
                                    })
                                end,
                            },
                            -- ── sections per ball ────────────────────────────
                            {
                                text_func = function()
                                    local nd = get("progress_dots_num_dots")
                                    local sp = get("progress_dots_sections")
                                    return ("Bars: %d sections/bar  (%d steps total)"):format(sp, nd * sp)
                                end,
                                enabled_func = function() return get("progress_dots_enabled") end,
                                keep_menu_open = true,
                                callback = function(tmi)
                                    UIManager:show(SpinWidget:new{
                                        title_text          = "Sections per ball",
                                        value               = get("progress_dots_sections"),
                                        value_min           = 1,
                                        value_max           = 100,
                                        value_step          = 1,
                                        default_value       = DEFAULTS.progress_dots_sections,
                                        keep_shown_on_apply = true,
                                        callback = function(spin)
                                            set("progress_dots_sections", spin.value)
                                            refreshProgress(tmi)
                                        end,
                                    })
                                end,
                            },
                                } end,
                            },
                            -- ── cover fill submenu ──────────────────────────
                            {
                                text = "Cover fill",
                                sub_item_table_func = function()
                                return {
                                -- ── cover fill toggle ───────────────────────
                                {
                                    text_func = function()
                                        return "Cover fill"
                                    end,
                                    checked_func = function() return get("cover_fill_enabled") end,
                                    callback = function(tmi)
                                        set("cover_fill_enabled", not get("cover_fill_enabled"))
                                        refreshProgress(tmi)
                                    end,
                                },
                                -- ── hide fill on finished books ──────────────
                                {
                                    text_func = function()
                                        return "Fill: hide on finished books"
                                    end,
                                    checked_func = function() return get("cover_fill_hide_on_finished") end,
                                    enabled_func = function() return get("cover_fill_enabled") end,
                                    callback = function(tmi)
                                        set("cover_fill_hide_on_finished", not get("cover_fill_hide_on_finished"))
                                        refreshProgress(tmi)
                                    end,
                                },
                                -- ── cover fill opacity ───────────────────────
                                {
                                    text_func = function()
                                        local v = math.floor(get("cover_fill_alpha") * 100 + 0.5)
                                        if v == 100 then return "Fill opacity: 100% (fully opaque)"
                                        elseif v == 0 then return "Fill opacity: 0% (fully transparent)"
                                        else return ("Fill opacity: %d%%"):format(v) end
                                    end,
                                    enabled_func = function() return get("cover_fill_enabled") end,
                                    keep_menu_open = true,
                                    callback = function(tmi)
                                        UIManager:show(SpinWidget:new{
                                            title_text          = "Cover fill opacity (0 = transparent, 100 = opaque)",
                                            value               = math.floor(get("cover_fill_alpha") * 100 + 0.5),
                                            value_min           = 0,
                                            value_max           = 100,
                                            value_step          = 5,
                                            default_value       = math.floor(DEFAULTS.cover_fill_alpha * 100 + 0.5),
                                            keep_shown_on_apply = true,
                                            value_text_func     = function(v) return v .. "%" end,
                                            callback = function(spin)
                                                set("cover_fill_alpha", spin.value / 100)
                                                refreshProgress(tmi)
                                            end,
                                        })
                                    end,
                                },
                                -- ── cover fill direction toggle ──────────────
                                {
                                    text_func = function()
                                        local ttb = get("cover_fill_top_to_bottom")
                                        return "Fill direction: " .. (ttb and "Top to bottom" or "Bottom to top (default)")
                                    end,
                                    enabled_func = function() return get("cover_fill_enabled") end,
                                    checked_func = function() return get("cover_fill_top_to_bottom") == true end,
                                    callback = function(tmi)
                                        set("cover_fill_top_to_bottom", not get("cover_fill_top_to_bottom"))
                                        refreshProgress(tmi)
                                    end,
                                },
                                {
                                    text_func = function()
                                        local key = get("cover_fill_color") or "BLACK"
                                        for _, entry in ipairs(DOTS_FILL_COLOR_MAP) do
                                            if entry.key == key then
                                                return "Fill color: " .. entry.label:gsub("%s+%b()",""):gsub("%s+$","")
                                            end
                                        end
                                        return "Fill color: White"
                                    end,
                                    enabled_func = function() return get("cover_fill_enabled") end,
                                    sub_item_table_func = function()
                                        local color_items = {}
                                        for _, entry in ipairs(DOTS_FILL_COLOR_MAP) do
                                            local ekey = entry.key
                                            table.insert(color_items, {
                                                text = entry.label,
                                                checked_func = function()
                                                    return (get("cover_fill_color") or "BLACK") == ekey
                                                end,
                                                callback = function()
                                                    set("cover_fill_color", ekey)
                                                    _cover_fill_color_cache = nil
                                                    _docinfo_cache = {}
                                                    local fc = require("ui/widget/filechooser")
                                                    if fc.instance then fc.instance:updateItems() end
                                                end,
                                            })
                                        end
                                        return color_items
                                    end,
                                },
                                } end,
                            },
                        }
                    end,
                },
                {
                    text = "Spine",
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
                                return "Series prefix: " .. (get("spine_series_prefix") and "On (e.g. \"1# Title\")" or "Off")
                            end,
                            checked_func = function() return get("spine_series_prefix") end,
                            enabled_func = function()
                                -- Only meaningful for metadata-based modes
                                local m = get("text_mode")
                                return m == "title" or m == "author_title" or m == "title_author"
                            end,
                            callback = function(touchmenu_instance)
                                set("spine_series_prefix", not get("spine_series_prefix"))
                                invalidateItemCache()
                                local fc = require("ui/widget/filechooser")
                                if fc.instance then fc.instance:updateItems() end
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        },
                        {
                            text_func = function()
                                local v = get("spine_width_pct")
                                if v == 150 then return "Spine width: 15.0% of cover (default)"
                                else return ("Spine width: %.1f%% of cover"):format(v / 10) end
                            end,
                            keep_menu_open = true,
                            callback = function(touchmenu_instance)
                                local SpinWidget = require("ui/widget/spinwidget")
                                local UIManager  = require("ui/uimanager")
                                UIManager:show(SpinWidget:new{
                                    title_text          = "Spine width (‰ of cover width)",
                                    value               = get("spine_width_pct"),
                                    value_min           = 50,
                                    value_max           = 400,
                                    value_step          = 5,
                                    default_value       = DEFAULTS.spine_width_pct,
                                    keep_shown_on_apply = true,
                                    value_text_func     = function(v) return ("%.1f%%"):format(v / 10) end,
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
                            text_func = function()
                                local v = get("spine_width_max_px")
                                if not v or v <= 0 then
                                    return "Spine width cap: off"
                                else
                                    return ("Spine width cap: %d px"):format(v)
                                end
                            end,
                            keep_menu_open = true,
                            callback = function(touchmenu_instance)
                                local SpinWidget = require("ui/widget/spinwidget")
                                local UIManager  = require("ui/uimanager")
                                UIManager:show(SpinWidget:new{
                                    title_text          = "Max spine width in pixels (0 = no cap)",
                                    value               = get("spine_width_max_px"),
                                    value_min           = 0,
                                    value_max           = 300,
                                    value_step          = 1,
                                    default_value       = DEFAULTS.spine_width_max_px,
                                    keep_shown_on_apply = true,
                                    value_text_func     = function(v)
                                        return v == 0 and "off" or (v .. " px")
                                    end,
                                    callback = function(spin)
                                        set("spine_width_max_px", spin.value)
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
                                local v = get("alpha")
                                return ("Spine opacity: %d%%"):format(math.floor(v * 100))
                            end,
                            keep_menu_open = true,
                            callback = function(touchmenu_instance)
                                local SpinWidget = require("ui/widget/spinwidget")
                                local UIManager  = require("ui/uimanager")
                                UIManager:show(SpinWidget:new{
                                    title_text          = "Spine opacity",
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
                            text = "Text style: Black on white",
                            checked_func = function() return not get("dark_mode") end,
                            callback = function(touchmenu_instance)
                                set("dark_mode", not get("dark_mode"))
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                                local fc = require("ui/widget/filechooser")
                                if fc.instance then fc.instance:updateItems() end
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
    _lines_cache         = {}
    invalidateItemCache()
    _docinfo_cache       = {}   -- unified DocSettings cache (replaces _progress_cache)
    _ranges_cache        = nil  -- re-read page-range thresholds for new folder
    _lines_enabled_cache = nil
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
    local ret = orig_genItemTableFromPath(self, path, ...)
    local items = ret or self.item_table or self.items
    primeVisibleBookCaches(items, 48)
    primeVisibleItemGeometry(items, 24)
    return ret
end

logger.info("mlabel: patch applied")
