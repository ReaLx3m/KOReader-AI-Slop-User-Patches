--[[
User patch: Remove the focus underline shown beneath the last visited
book or folder in mosaic view.

Installation:
  Copy this file to:  koreader/patches/2-no-focus-underline.lua
--]]

local Blitbuffer = require("ffi/blitbuffer")
local userpatch  = require("userpatch")
local logger     = require("logger")

local function patchCoverBrowser(plugin)
    local MosaicMenu = require("mosaicmenu")
    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
    if not MosaicMenuItem then return end

    function MosaicMenuItem:onFocus()
        self._underline_container.color = Blitbuffer.COLOR_WHITE
        return true
    end
end

userpatch.registerPatchPluginFunc("coverbrowser", patchCoverBrowser)

logger.info("no-focus-underline: patch applied")
