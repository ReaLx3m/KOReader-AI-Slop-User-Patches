--[[
User patch: Show a semi-transparent vertical label on the left or right side
of each cover in mosaic view, rotated 90°.

Label text options:
  • filename        – filename without extension (default)
  • title           – metadata title
  • author_title    – "Author – Title"
  • title_author    – "Title – Author"

Position: left (default) or right

Settings exposed under: Settings → Mosaic label

Installation:
  Copy this file to:  koreader/patches/2-mosaic-vertical-label-left.lua
--]]

-- ── defaults ──────────────────────────────────────────────────────────────────
local DEFAULTS = {
    enabled    = true,
    position   = "left",     -- "left" | "right"
    direction  = "up",       -- "up" (bottom→top) | "down" (top→bottom)
    text_mode  = "filename", -- "filename" | "title" | "author_title" | "title_author"
    alpha      = 0.80,
    font_size  = 16,
    padding    = 4,
}

-- ── requires ──────────────────────────────────────────────────────────────────
local FileChooser      = require("ui/widget/filechooser")
local FileManagerMenu  = require("apps/filemanager/filemanagermenu")
local FileManagerMenuOrder = require("ui/elements/filemanager_menu_order")
local Blitbuffer       = require("ffi/blitbuffer")
local Font             = require("ui/font")
local TextWidget       = require("ui/widget/textwidget")
local FrameContainer   = require("ui/widget/container/framecontainer")
local CenterContainer  = require("ui/widget/container/centercontainer")
local AlphaContainer   = require("ui/widget/container/alphacontainer")
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
local _strip_w_font  = nil
local function getStripW()
    local fs = get("font_size")
    if _strip_w_cache and _strip_w_font == fs then return _strip_w_cache end
    local tw = TextWidget:new{ text = "A", face = Font:getFace("cfont", fs) }
    local pad = get("padding")
    _strip_w_cache = math.floor((tw:getSize().h + 2 * pad) * 0.9)
    _strip_w_font  = fs
    tw:free()
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

-- ── blitbuffer edge scan ──────────────────────────────────────────────────────
local function findCoverEdges(bb, cell_x, cell_w, cell_y, cell_h)
    local mid_y = cell_y + math.floor(cell_h / 2)
    local left_offset  = 0
    local right_offset = 0
    for col = 0, cell_w - 1 do
        local c = bb:getPixel(cell_x + col, mid_y)
        if c and c:getR() < 250 then left_offset = col; break end
    end
    for col = cell_w - 1, 0, -1 do
        local c = bb:getPixel(cell_x + col, mid_y)
        if c and c:getR() < 250 then right_offset = cell_w - 1 - col; break end
    end
    -- also scan vertically at the cover's horizontal midpoint to find top/bottom
    local mid_x = cell_x + math.floor(cell_w / 2)
    local top_offset    = 0
    local bottom_offset = 0
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

    local orig_update  = MosaicMenuItem.update
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

        local strip_w = getStripW()
        local pos     = get("position")
        local pad     = get("padding")
        local fs      = get("font_size")
        local alpha   = get("alpha")

        -- find cover edges so we can sit flush against the cover box
        local left_off, right_off, top_off, bottom_off = findCoverEdges(bb, x, item_w, y, item_h)

        -- actual cover height (may be less than item_h in non-square grids)
        local cover_y = y + top_off
        local cover_h = item_h - top_off - bottom_off
        if cover_h <= 0 then return end

        -- label_x: just outside the cover edge on the chosen side
        local label_x
        if pos == "right" then
            label_x = x + (item_w - right_off)
            if label_x + strip_w > x + item_w then
                label_x = x + item_w - strip_w
            end
        else
            label_x = x + left_off - strip_w
            if label_x < x then label_x = x end
        end

        -- build label widget sized to actual cover height
        local text_widget = TextWidget:new{
            text      = name,
            face      = Font:getFace("cfont", fs),
            fgcolor   = Blitbuffer.COLOR_WHITE,
            max_width = cover_h - 2 * pad,
        }
        local label = AlphaContainer:new{
            alpha = alpha,
            FrameContainer:new{
                background = Blitbuffer.COLOR_BLACK,
                bordersize = 0,
                padding    = 0,
                width      = cover_h,
                height     = strip_w,
                CenterContainer:new{
                    dimen = Geom:new{ w = cover_h, h = strip_w },
                    text_widget,
                },
            },
        }

        -- composite against real background pixels
        local tmp = Blitbuffer.new(cover_h, strip_w, bb:getType())
        tmp:blitFrom(bb, 0, 0, label_x, cover_y, cover_h, strip_w)
        label:paintTo(tmp, 0, 0)
        label:free()

        -- rotate and blit back
        local angle   = (get("direction") == "down") and 270 or 90
        local rotated = tmp:rotatedCopy(angle)
        tmp:free()
        bb:blitFrom(rotated, label_x, cover_y, 0, 0, strip_w, cover_h)
        rotated:free()
    end
end

-- ── menu ──────────────────────────────────────────────────────────────────────
local orig_setUpdateItemTable = FileManagerMenu.setUpdateItemTable
function FileManagerMenu:setUpdateItemTable()
    -- inject into filemanager_settings if present
    if type(FileManagerMenuOrder.filemanager_settings) == "table" then
        local found = false
        for _, k in ipairs(FileManagerMenuOrder.filemanager_settings) do
            if k == "mosaic_vlabel_menu" then found = true; break end
        end
        if not found then
            table.insert(FileManagerMenuOrder.filemanager_settings, 1, "mosaic_vlabel_menu")
        end
    end

    self.menu_items.mosaic_vlabel_menu = {
        text = "Mosaic Vertical Label Advanced",
        sub_item_table_func = function()
            return {
                {
                    text_func = function()
                        return get("enabled") and "Mosaic label: enabled" or "Mosaic label: disabled"
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
                    text = "Position",
                    sub_item_table = {
                        {
                            text = "Left",
                            checked_func = function() return get("position") == "left" end,
                            callback = function()
                                set("position", "left")
                                local fc = require("ui/widget/filechooser")
                                if fc.instance then fc.instance:updateItems() end
                            end,
                        },
                        {
                            text = "Right",
                            checked_func = function() return get("position") == "right" end,
                            callback = function()
                                set("position", "right")
                                local fc = require("ui/widget/filechooser")
                                if fc.instance then fc.instance:updateItems() end
                            end,
                        },
                    },
                },
                {
                    text = "Text direction",
                    sub_item_table = {
                        {
                            text = "Bottom to top",
                            checked_func = function() return get("direction") == "up" end,
                            callback = function()
                                set("direction", "up")
                                local fc = require("ui/widget/filechooser")
                                if fc.instance then fc.instance:updateItems() end
                            end,
                        },
                        {
                            text = "Top to bottom",
                            checked_func = function() return get("direction") == "down" end,
                            callback = function()
                                set("direction", "down")
                                local fc = require("ui/widget/filechooser")
                                if fc.instance then fc.instance:updateItems() end
                            end,
                        },
                    },
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
                    },
                },
            }
        end,
    }

    orig_setUpdateItemTable(self)
end

-- ── hook into genItemTableFromPath to grab MosaicMenuItem ────────────────────
local orig_genItemTableFromPath = FileChooser.genItemTableFromPath
function FileChooser:genItemTableFromPath(path, ...)
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
