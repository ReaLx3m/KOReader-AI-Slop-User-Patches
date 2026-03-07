--[[
User patch: Show a semi-transparent vertical filename label (without extension)
on the left side of each cover in mosaic view, rotated 90 degrees.

Installation:
  Copy this file to:  koreader/patches/2-mosaic-filename-label.lua

Customise the constants below if needed.
--]]

local LABEL_ALPHA      = 0.80  -- 0.0 = fully transparent, 1.0 = fully opaque
local LABEL_FONT_SIZE  = 16    -- font size in points
local LABEL_PADDING    = 4     -- padding in pixels around the text

local FileChooser    = require("ui/widget/filechooser")
local Blitbuffer     = require("ffi/blitbuffer")
local Font           = require("ui/font")
local TextWidget     = require("ui/widget/textwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local AlphaContainer = require("ui/widget/container/alphacontainer")
local userpatch      = require("userpatch")
local util           = require("util")
local logger         = require("logger")

if FileChooser._mosaic_filename_label_patched then return end
FileChooser._mosaic_filename_label_patched = true

local function patchMosaicMenuItem(MosaicMenuItem)
    if MosaicMenuItem._filename_label_patched then return end
    MosaicMenuItem._filename_label_patched = true

    local orig_paintTo = MosaicMenuItem.paintTo
    MosaicMenuItem.paintTo = function(self, bb, x, y)
        orig_paintTo(self, bb, x, y)

        local raw = self.filepath or self.text or ""
        local _, filename = util.splitFilePathName(raw)
        local name, ext = util.splitFileNameSuffix(filename)
        -- skip folders (no extension)
        if ext == "" then return end
        if name == "" then return end

        local item_w = self.dimen and self.dimen.w or self.width or 0
        local item_h = self.dimen and self.dimen.h or self.height or 0
        if item_w == 0 or item_h == 0 then return end

        -- Build the text widget to measure it
        local CenterContainer = require("ui/widget/container/centercontainer")
        local max_text_w = item_h - 2 * LABEL_PADDING

        local text_widget = TextWidget:new{
            text      = name,
            face      = Font:getFace("cfont", LABEL_FONT_SIZE),
            fgcolor   = Blitbuffer.COLOR_WHITE,
            max_width = max_text_w,
        }

        -- Box is always item_h wide (before rotation) × label_height tall
        local label_h = math.floor((text_widget:getSize().h + 2 * LABEL_PADDING) * 0.9)

        local label = AlphaContainer:new{
            alpha = LABEL_ALPHA,
            FrameContainer:new{
                background = Blitbuffer.COLOR_BLACK,
                bordersize = 0,
                padding    = 0,
                width      = item_h,
                height     = label_h,
                CenterContainer:new{
                    dimen = { w = item_h, h = label_h },
                    text_widget,
                },
            },
        }

        local lw = item_h   -- will become height after rotation
        local lh = label_h  -- will become width after rotation

        -- The box is item_h wide (before rotation) x label_h tall
        -- Copy the actual cover pixels into tmp first so AlphaContainer
        -- composites against the real background, not white
        local tmp = Blitbuffer.new(lw, lh, bb:getType())
        tmp:blitFrom(bb, 0, 0, x, y, lw, lh)
        label:paintTo(tmp, 0, 0)
        label:free()

        -- Rotate 90° counter-clockwise so text reads bottom-to-top
        local rotated = tmp:rotatedCopy(90)
        tmp:free()

        -- rotated dimensions: w=lh, h=lw
        -- Paint on the left edge, vertically centered
        local rx = x
        local ry = y + math.floor((item_h - lw) / 2)
        bb:blitFrom(rotated, rx, ry, 0, 0, lh, lw)
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
