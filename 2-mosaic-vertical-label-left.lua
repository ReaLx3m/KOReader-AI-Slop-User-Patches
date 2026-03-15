--[[
User patch: Show a semi-transparent vertical filename label (without extension)
on the left side of each cover in mosaic view, rotated 90 degrees.

The label is painted flush against the cover's actual left edge, found by
scanning the blitbuffer. The cover is rendered normally (no width tricks).

Installation:
  Copy this file to:  koreader/patches/2-mosaic-vertical-label-left.lua
--]]

local LABEL_ALPHA     = 0.80
local LABEL_FONT_SIZE = 16
local LABEL_PADDING   = 4

local FileChooser    = require("ui/widget/filechooser")
local Blitbuffer     = require("ffi/blitbuffer")
local Font           = require("ui/font")
local TextWidget     = require("ui/widget/textwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer= require("ui/widget/container/centercontainer")
local AlphaContainer = require("ui/widget/container/alphacontainer")
local Geom           = require("ui/geometry")
local userpatch      = require("userpatch")
local util           = require("util")
local logger         = require("logger")

if FileChooser._mosaic_filename_label_patched then return end
FileChooser._mosaic_filename_label_patched = true

local _label_strip_w = nil
local function getLabelStripW()
    if _label_strip_w then return _label_strip_w end
    local tw = TextWidget:new{
        text = "A",
        face = Font:getFace("cfont", LABEL_FONT_SIZE),
    }
    _label_strip_w = math.floor((tw:getSize().h + 2 * LABEL_PADDING) * 0.9)
    tw:free()
    return _label_strip_w
end

-- Scan blitbuffer to find cover edges horizontally and vertically.
local function findCoverEdges(bb, cell_x, cell_w, cell_y, cell_h)
    local mid_y = cell_y + math.floor(cell_h / 2)
    local left_offset = 0
    for col = 0, cell_w - 1 do
        local c = bb:getPixel(cell_x + col, mid_y)
        if c and c:getR() < 250 then left_offset = col; break end
    end
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
    return left_offset, top_offset, bottom_offset
end

local function patchMosaicMenuItem(MosaicMenuItem)
    if MosaicMenuItem._filename_label_patched then return end
    MosaicMenuItem._filename_label_patched = true

    local orig_paintTo = MosaicMenuItem.paintTo

    MosaicMenuItem.paintTo = function(self, bb, x, y)
        orig_paintTo(self, bb, x, y)

        if self.is_directory then return end

        local item_w = self.dimen and self.dimen.w or self.width or 0
        local item_h = self.dimen and self.dimen.h or self.height or 0
        if item_w == 0 or item_h == 0 then return end

        local raw = self.filepath or self.text or ""
        local _, filename = util.splitFilePathName(raw)
        local name = util.splitFileNameSuffix(filename)
        if name == "" then return end

        local strip_w = getLabelStripW()

        -- Find cover edges; clip label to actual cover bounds.
        local cover_left, top_off, bottom_off = findCoverEdges(bb, x, item_w, y, item_h)
        local cover_y = y + top_off
        local cover_h = item_h - top_off - bottom_off
        if cover_h <= 0 then return end

        local cover_x = x + cover_left
        local text_widget = TextWidget:new{
            text      = name,
            face      = Font:getFace("cfont", LABEL_FONT_SIZE),
            fgcolor   = Blitbuffer.COLOR_WHITE,
            max_width = cover_h - 2 * LABEL_PADDING,
        }

        local label = AlphaContainer:new{
            alpha = LABEL_ALPHA,
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

        -- Place label just to the left of the cover's left edge.
        local label_x = x + cover_left - strip_w
        if label_x < x then label_x = x end

        -- Composite against left edge of cover (vertical strip).
        local tmp = Blitbuffer.new(cover_h, strip_w, bb:getType())
        local src = Blitbuffer.new(strip_w, cover_h, bb:getType())
        src:blitFrom(bb, 0, 0, cover_x, cover_y, strip_w, cover_h)
        local src_rot = src:rotatedCopy(270)
        src:free()
        tmp:blitFrom(src_rot, 0, 0, 0, 0, cover_h, strip_w)
        src_rot:free()
        label:paintTo(tmp, 0, 0)
        label:free()

        -- Rotate 90° CCW: now strip_w wide x cover_h tall.
        local rotated = tmp:rotatedCopy(90)
        tmp:free()

        bb:blitFrom(rotated, label_x, cover_y, 0, 0, strip_w, cover_h)
        rotated:free()
    end
end

local orig_genItemTableFromPath = FileChooser.genItemTableFromPath
function FileChooser:genItemTableFromPath(path, ...)
    if not FileChooser._mosaic_label_done then
        local ok, MosaicMenu = pcall(require, "mosaicmenu")
        if ok and MosaicMenu then
            local MM = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
            if MM then
                patchMosaicMenuItem(MM)
                FileChooser._mosaic_label_done = true
            end
        end
    end
    return orig_genItemTableFromPath(self, path, ...)
end

logger.info("mlabel: patch applied")
