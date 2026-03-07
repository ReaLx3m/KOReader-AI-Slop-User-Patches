--[[
User patch: Show a semi-transparent filename label (without extension)
at the top of each cover in mosaic view.

Installation:
  Copy this file to:  koreader/patches/2-mosaic-filename-label.lua

Customise the constants below if needed.
--]]

local LABEL_ALPHA      = 0.75  -- 0.0 = fully transparent, 1.0 = fully opaque
local LABEL_FONT_SIZE  = 14    -- font size in points
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

        local box_w = math.floor(item_w * 0.9)
        local max_text_w = box_w - 2 * LABEL_PADDING

        local label = AlphaContainer:new{
            alpha = LABEL_ALPHA,
            FrameContainer:new{
                background     = Blitbuffer.COLOR_BLACK,
                bordersize     = 0,
                padding        = LABEL_PADDING,
                padding_top    = LABEL_PADDING,
                padding_bottom = LABEL_PADDING,
                TextWidget:new{
                    text      = name,
                    face      = Font:getFace("cfont", LABEL_FONT_SIZE),
                    fgcolor   = Blitbuffer.COLOR_WHITE,
                    max_width = max_text_w,
                },
            },
        }

        -- Center horizontally within the item cell, paint at top
        local lw = label:getSize().w
        local lx = x + math.floor((item_w - lw) / 2)
        label:paintTo(bb, lx, y)
        label:free()
    end
end

local orig_genItemTableFromPath = FileChooser.genItemTableFromPath
function FileChooser:genItemTableFromPath(path, ...)
    if FileChooser._updateItemsBuildUI and not FileChooser._mosaic_label_done then
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
