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

-- Scan blitbuffer columns from x=start leftward to find first non-white pixel
-- at the vertical midpoint. Returns the column offset from cell_x.
local function findCoverLeftEdge(bb, cell_x, cell_w, cell_y, cell_h)
    local mid_y = cell_y + math.floor(cell_h / 2)
    for col = 0, cell_w - 1 do
        local c = bb:getPixel(cell_x + col, mid_y)
        if c and c:getR() < 250 then
            return col
        end
    end
    return 0
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

        -- Find where the cover image actually starts (may be indented due to
        -- center-alignment of narrow covers within the cell).
        local cover_left = findCoverLeftEdge(bb, x, item_w, y, item_h)

        -- Label box: item_h wide x strip_w tall (before 90° rotation).
        local text_widget = TextWidget:new{
            text      = name,
            face      = Font:getFace("cfont", LABEL_FONT_SIZE),
            fgcolor   = Blitbuffer.COLOR_WHITE,
            max_width = item_h - 2 * LABEL_PADDING,
        }

        local label = AlphaContainer:new{
            alpha = LABEL_ALPHA,
            FrameContainer:new{
                background = Blitbuffer.COLOR_BLACK,
                bordersize = 0,
                padding    = 0,
                width      = item_h,
                height     = strip_w,
                CenterContainer:new{
                    dimen = Geom:new{ w = item_h, h = strip_w },
                    text_widget,
                },
            },
        }

        -- Place the label just to the LEFT of the cover's left edge.
        -- Clamped so it never goes outside the cell's left boundary.
        local label_x = x + cover_left - strip_w
        if label_x < x then label_x = x end

        -- Composite against the background pixels at the label's actual position.
        -- Before rotation the buffer is item_h wide x strip_w tall.
        local tmp = Blitbuffer.new(item_h, strip_w, bb:getType())
        tmp:blitFrom(bb, 0, 0, label_x, y, item_h, strip_w)
        label:paintTo(tmp, 0, 0)
        label:free()

        -- Rotate 90° CCW: now strip_w wide x item_h tall.
        local rotated = tmp:rotatedCopy(90)
        tmp:free()

        bb:blitFrom(rotated, label_x, y, 0, 0, strip_w, item_h)
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
