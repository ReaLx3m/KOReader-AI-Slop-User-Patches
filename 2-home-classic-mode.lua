--[[
User patch: Use Classic (filename only) view in the home folder,
mosaic_image everywhere else.

Installation:
  Copy this file to:  koreader/patches/2-home-classic-mode.lua

Customise the two constants below if needed.
--]]

local HOME_PATH   = "/mnt/ext1/1Stripovi"  -- full path to your home folder
local NORMAL_MODE = "mosaic_image"          -- mode used everywhere else

local userpatch   = require("userpatch")
local FileChooser = require("ui/widget/filechooser")
local logger      = require("logger")

if FileChooser._home_classic_patched then return end
FileChooser._home_classic_patched = true

local _ready = false
local _curr_modes
local _orig_updateItems, _orig_recalcDimen, _orig_onClose
local _mosaic_updateItems, _mosaic_recalcDimen, _mosaic_updateItemsBuildUI
local _in_home
local _saved_home_page = 1
local _restore_page_pending

local function setup(fc)
    if _ready then return true end

    local cb = fc.show_parent and fc.show_parent.coverbrowser
    if not cb or not cb.setupFileManagerDisplayMode then return false end

    local setupFn     = cb.setupFileManagerDisplayMode
    _curr_modes       = userpatch.getUpValue(setupFn, "curr_display_modes")
    _orig_updateItems = userpatch.getUpValue(setupFn, "_FileChooser_updateItems_orig")
    _orig_recalcDimen = userpatch.getUpValue(setupFn, "_FileChooser__recalculateDimen_orig")
    _orig_onClose     = userpatch.getUpValue(setupFn, "_FileChooser_onCloseWidget_orig")

    if not _curr_modes or not _orig_updateItems then return false end

    _mosaic_updateItems        = FileChooser.updateItems
    _mosaic_recalcDimen        = FileChooser._recalculateDimen
    _mosaic_updateItemsBuildUI = FileChooser._updateItemsBuildUI

    _ready = true
    return true
end

local function applyModeForPath(fc, path)
    if not setup(fc) then return end
    local is_home = ((path or ""):gsub("/$", "") == HOME_PATH)
    if _in_home == is_home then return end
    _in_home = is_home

    if is_home then
        FileChooser.updateItems             = _orig_updateItems
        FileChooser._recalculateDimen       = _orig_recalcDimen
        FileChooser.onCloseWidget           = _orig_onClose
        FileChooser._updateItemsBuildUI     = nil
        FileChooser._do_cover_images        = nil
        FileChooser.display_mode            = nil
        FileChooser.display_mode_type       = nil
        _curr_modes["filemanager"]          = nil
        _restore_page_pending               = true
    else
        FileChooser.updateItems             = _mosaic_updateItems
        FileChooser._recalculateDimen       = _mosaic_recalcDimen
        FileChooser._updateItemsBuildUI     = _mosaic_updateItemsBuildUI
        FileChooser._do_cover_images        = true
        FileChooser._do_center_partial_rows = false
        FileChooser.display_mode            = NORMAL_MODE
        FileChooser.display_mode_type       = "mosaic"
        _curr_modes["filemanager"]          = NORMAL_MODE
    end
end

-- Save page when leaving home
local orig_changeToPath = FileChooser.changeToPath
function FileChooser:changeToPath(path, focused_path)
    if (self.path or ""):gsub("/$", "") == HOME_PATH then
        _saved_home_page = self.page or 1
    end
    return orig_changeToPath(self, path, focused_path)
end

-- Restore page AFTER switchItemTable has set self.page
local orig_switchItemTable = FileChooser.switchItemTable
function FileChooser:switchItemTable(...)
    orig_switchItemTable(self, ...)
    if _restore_page_pending then
        _restore_page_pending = false
        if self.page ~= _saved_home_page then
            self.page = _saved_home_page
            self:updateItems()
        end
    end
end

local orig_genItemTableFromPath = FileChooser.genItemTableFromPath
function FileChooser:genItemTableFromPath(path, ...)
    applyModeForPath(self, path)
    return orig_genItemTableFromPath(self, path, ...)
end

logger.info("home-classic: patch applied")
