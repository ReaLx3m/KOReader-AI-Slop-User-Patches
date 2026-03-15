--[[
User patch: Show a semi-transparent vertical label on the left side
of each cover in mosaic view, rotated 90°.
Lines above cover are dynamic based on page count (configurable).

Label text options:
  • filename        – filename without extension (default)
  • title           – metadata title
  • author_title    – "Author – Title"
  • title_author    – "Title – Author"

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
end

-- ── cached strip width (invalidated when font_size changes via menu) ──────────
local _strip_w_cache = nil
local _strip_w_key   = nil
local function getStripW(item_w)
    local fs  = get("font_size")
    local key = fs .. (item_w or 0)
    if _strip_w_cache and _strip_w_key == key then return _strip_w_cache end
    local pad = get("padding")
    local tw = TextWidget:new{ text = "A", face = Font:getFace("cfont", fs) }
    local font_h = tw:getSize().h
    tw:free()
    local max_w = math.floor((font_h + 2 * pad) * 0.75)  -- original size = max
    if item_w and item_w > 0 then
        local scaled = math.floor(item_w * 0.15)
        _strip_w_cache = math.min(max_w, scaled)
    else
        _strip_w_cache = max_w
    end
    _strip_w_key = key
    return _strip_w_cache
end

-- ── BookInfoManager lazy grab ─────────────────────────────────────────────────
local _BookInfoManager
local function getBIM()
    if not _BookInfoManager then
        -- Direct require (it's a module inside the coverbrowser plugin)
        local ok, bim = pcall(require, "bookinfomanager")
        if ok and bim then
            _BookInfoManager = bim
        else
            -- Fallback: walk upvalue chain from _updateItemsBuildUI → MosaicMenuItem.update
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

    -- metadata modes — try BookInfoManager
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

    -- fallback to filename
    local _, filename = util.splitFilePathName(raw)
    return util.splitFileNameSuffix(filename)
end

-- ── page count → line count ───────────────────────────────────────────────────
local _lines_cache = {}  -- filepath → num_lines, once resolved

local function getPageCount(filepath)
    if not filepath then return nil end

    -- first: try doc settings (most reliable, requires book opened once)
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

    -- fallback: try BIM (populated by cover browser background scan)
    local bim = getBIM()
    if bim then
        local ok2, bookinfo = pcall(function() return bim:getBookInfo(filepath, false) end)
        if ok2 and bookinfo then
            if bookinfo.nb_pages and bookinfo.nb_pages > 0 then return bookinfo.nb_pages end
        end
    end

    -- fallback: parse page count from filename e.g. "Book Title p234.epub"
    local fname = filepath:match("([^/]+)$") or ""
    local p = fname:match("[Pp](%d+)%.")
    if p then return tonumber(p) end

    -- fallback: estimate from file size
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

    -- find the tier by walking from lowest to highest, skipping disabled tiers
    local n = max_lines  -- default to max
    for i = 1, max_lines - 1 do
        local tier = i + 1  -- tier 2 is index 1, tier 3 is index 2, etc.
        if get("lines_enabled_" .. tier) == false then goto continue end
        if pages <= (ranges[i] or math.huge) then
            n = tier
            break
        end
        ::continue::
    end
    -- if max tier itself is disabled, walk down to nearest enabled
    while n > 2 and get("lines_enabled_" .. n) == false do
        n = n - 1
    end

    _lines_cache[filepath] = n
    return n
end

-- ── blitbuffer edge scan ──────────────────────────────────────────────────────
local function findCoverEdges(bb, cell_x, cell_w, cell_y, cell_h)
    -- Scan multiple rows near the top (where background is most likely white)
    -- and take the maximum left_offset found (widest white margin = true edge)
    local left_offset  = 0
    local right_offset = 0
    local top_offset   = 0
    local bottom_offset = 0

    -- scan several rows in top quarter to find the widest white margin
    local scan_rows = math.floor(cell_h * 0.25)
    for row = 0, scan_rows do
        local sy = cell_y + row
        local lo = 0
        for col = 0, cell_w - 1 do
            local c = bb:getPixel(cell_x + col, sy)
            if c and c:getR() < 250 then lo = col; break end
        end
        if lo > left_offset then left_offset = lo end
        local ro = 0
        for col = cell_w - 1, 0, -1 do
            local c = bb:getPixel(cell_x + col, sy)
            if c and c:getR() < 250 then ro = cell_w - 1 - col; break end
        end
        if ro > right_offset then right_offset = ro end
    end

    -- vertical scan at horizontal midpoint
    local mid_x = cell_x + math.floor(cell_w / 2)
    for row = 0, cell_h - 1 do
        local c = bb:getPixel(mid_x, cell_y + row)
        if c and c:getR() < 250 then top_offset = row; break end
    end
    for row = cell_h - 1, 0, -1 do
        local c = bb:getPixel(mid_x, cell_y + row)
        if c and c:getR() < 250 then bottom_offset = cell_h - 1 - row; break end
    end
    return left_offset, right_offset, top_offset, bottom_offset
end

-- ── core patch ────────────────────────────────────────────────────────────────
local function patchMosaicMenuItem(MosaicMenuItem)
    if MosaicMenuItem._vlabel_patched then return end
    MosaicMenuItem._vlabel_patched = true

    local orig_paintTo = MosaicMenuItem.paintTo

    MosaicMenuItem.paintTo = function(self, bb, x, y)
        orig_paintTo(self, bb, x, y)

        if not get("enabled") then return end
        if self.is_directory then return end

        local item_w = self.dimen and self.dimen.w or self.width  or 0
        local item_h = self.dimen and self.dimen.h or self.height or 0
        if item_w == 0 or item_h == 0 then return end

        local name = getLabelText(self)
        if not name or name == "" then return end

        local strip_w = getStripW(item_w)
        local pad     = get("padding")
        local fs      = get("font_size")
        local alpha   = get("alpha")

        -- find cover edges so we can sit flush against the cover box
        local left_off, right_off, top_off, bottom_off = findCoverEdges(bb, x, item_w, y, item_h)

        -- actual cover height (may be less than item_h in non-square grids)
        local cover_y = y + top_off
        local cover_h = item_h - top_off - bottom_off
        if cover_h <= 0 then return end

        local cover_x = x + left_off
        local cover_w = item_w - left_off - right_off

        -- label sits just to the left of the cover edge
        local label_x = math.max(x, cover_x - strip_w)

        -- angle cut depths (defined early so l_total can reference cut_h_top)
        local cut_h_bot = math.floor(strip_w * 0.5774)  -- tan(30°)

        -- dynamic line count based on page count
        local page_thick = get("page_thickness")
        local page_gap   = get("page_spacing")
        local line_step  = page_thick + page_gap
        local num_lines  = getNumLines(self.filepath or self.text)
        local l_total    = num_lines * line_step
        local label_y    = cover_y - l_total
        local label_h    = cover_h + l_total

        -- top angle always spans exactly l_total so right corner anchors to cover_y
        local cut_h_top  = l_total

        -- text max_width excludes the angled cut areas so text stays within visible box
        local text_max_w = label_h - cut_h_top - cut_h_bot - 2 * pad

        -- resolve font filename from face + bold settings
        local font_map = {
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
        local face_entry = font_map[get("font_face")] or font_map["NotoSerif"]
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
        -- dark mode: black bg + white text / light mode: white bg + black text
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
        local tmp = sheared

        local rotated = tmp:rotatedCopy(angle)
        tmp:free()

        -- save background strip before we draw (so we can restore corners)
        local bg = Blitbuffer.new(strip_w, label_h, bb:getType())
        bg:blitFrom(bb, 0, 0, label_x, label_y, strip_w, label_h)

        -- blit the full rotated rectangle
        bb:blitFrom(rotated, label_x, label_y, 0, 0, strip_w, label_h)
        rotated:free()

        for row = 0, math.max(cut_h_top, cut_h_bot) - 1 do
            local brow = label_h - 1 - row
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

        -- draw lines above cover, clipped at label's right edge (accounting for angle)
        do
            local color  = Blitbuffer.COLOR_GRAY_4
            local shrink = math.floor(cover_w * 0.025)

            for i = 1, num_lines do
                local by = cover_y - page_thick - page_gap - (i - 1) * line_step
                local line_end = x + math.floor((cover_x - x + cover_w) * 0.975) - (i - 1) * shrink
                local row_in_cut = by - label_y
                local line_start
                if row_in_cut >= 0 and row_in_cut < cut_h_top then
                    local t = (cut_h_top - row_in_cut) / cut_h_top
                    local trim = math.floor(t ^ 0.6 * strip_w)
                    line_start = label_x + strip_w - trim
                else
                    line_start = label_x + strip_w
                end
                local draw_len = line_end - line_start
                local line_color = (i == num_lines) and Blitbuffer.COLOR_GRAY_2 or color
                if draw_len > 0 then
                    bb:paintRect(line_start, by, draw_len, page_thick, line_color)
                end
            end
        end
    end
end

-- ── menu ──────────────────────────────────────────────────────────────────────
local orig_setUpdateItemTable = FileManagerMenu.setUpdateItemTable
function FileManagerMenu:setUpdateItemTable()
    -- Inject "ai_slop_settings" into the filing-cabinet Settings tab once.
    if type(FileManagerMenuOrder.filemanager_settings) == "table" then
        local found = false
        for _, k in ipairs(FileManagerMenuOrder.filemanager_settings) do
            if k == "ai_slop_settings" then found = true; break end
        end
        if not found then
            table.insert(FileManagerMenuOrder.filemanager_settings, 1, "ai_slop_settings")
        end
    end

    -- "AI Slop Settings" parent entry (shared across patches — only define once).
    if not self.menu_items.ai_slop_settings then
        self.menu_items.ai_slop_settings = {
            text = "AI Slop Settings",
            sub_item_table = {},
        }
    end

    -- Append Mosaic Label sub-entry (guard against duplicate injection).
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
                {
                    text_func = function()
                        return get("enabled") and "Real Books: enabled" or "Real Books: disabled"
                    end,
                    checked_func = function() return get("enabled") end,
                    callback = function(touchmenu_instance)
                        set("enabled", not get("enabled"))
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                        local fc = require("ui/widget/filechooser")
                        if fc.instance then fc.instance:updateItems() end
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
                                    value_max           = 16,
                                    value_step          = 1,
                                    default_value       = DEFAULTS.font_size,
                                    keep_shown_on_apply = true,
                                    callback = function(spin)
                                        set("font_size", spin.value)
                                        _strip_w_cache = nil
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
                {
                    text = "Page lines",
                    sub_item_table_func = function()
                        local SpinWidget = require("ui/widget/spinwidget")
                        local UIManager  = require("ui/uimanager")
                        local function refresh(tmi)
                            _lines_cache = {}
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
                                text = "Show line tiers",
                                sub_item_table_func = function()
                                    local tier_items = {}
                                    for n = 2, 10 do
                                        local key = "lines_enabled_" .. n
                                        local nn = n  -- capture
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
                            -- show range if tier+1 is enabled AND not the highest enabled tier
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
                                -- find highest enabled tier
                                local highest = 2
                                for tier = 10, 2, -1 do
                                    if get("lines_enabled_" .. tier) ~= false then
                                        highest = tier
                                        break
                                    end
                                end
                                -- its threshold is the range of the tier below it
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
    -- clear page count cache on folder change so BIM is retried for new books
    _lines_cache = {}
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
