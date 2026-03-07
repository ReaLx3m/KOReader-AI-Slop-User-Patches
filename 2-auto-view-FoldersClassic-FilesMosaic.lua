--[[
User patch: Automatically use Classic (filename only) view in any folder that
contains at least one subfolder; use mosaic_image in folders that contain only
files (no subfolders).

  - Mixed or dir-only folders  → Classic view
  - Pure-file folders          → Mosaic view

Installation:
  Copy this file to:  koreader/patches/2-auto-classic-mode.lua

Customise the constant below if needed.
--]]

local MOSAIC_MODE = "mosaic_image"   -- mode used in file-only folders

local userpatch   = require("userpatch")
local FileChooser = require("ui/widget/filechooser")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")

if FileChooser._auto_classic_patched then return end
FileChooser._auto_classic_patched = true

local _ready = false
local _curr_modes
local _orig_updateItems, _orig_recalcDimen, _orig_onClose
local _mosaic_updateItems, _mosaic_recalcDimen, _mosaic_updateItemsBuildUI
local _current_want_classic  -- last applied state: true=classic, false=mosaic, nil=unknown

-- ── setup: grab coverbrowser upvalues once ────────────────────────────────────

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

-- ── subdir detection using lfs (same backend FileChooser:getList uses) ────────
-- Returns true if `path` contains at least one visible subdirectory,
-- honouring FileChooser.show_hidden exactly as KOReader does.

local function pathHasSubdirs(path)
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok then return false end
    for f in iter, dir_obj do
        if f ~= "." and f ~= ".." then
            if FileChooser.show_hidden or f:sub(1, 1) ~= "." then
                local attr = lfs.attributes(path .. "/" .. f)
                if attr and attr.mode == "directory" then
                    return true
                end
            end
        end
    end
    return false
end

-- ── mode switcher ─────────────────────────────────────────────────────────────

local function applyModeForPath(fc, path)
    if not setup(fc) then return end

    local want_classic = pathHasSubdirs(path)

    -- no-op if mode already matches
    if _current_want_classic == want_classic then return end
    _current_want_classic = want_classic

    if want_classic then
        -- Restore original Classic (plain list) functions
        FileChooser.updateItems             = _orig_updateItems
        FileChooser._recalculateDimen       = _orig_recalcDimen
        FileChooser.onCloseWidget           = _orig_onClose
        FileChooser._updateItemsBuildUI     = nil
        FileChooser._do_cover_images        = nil
        FileChooser.display_mode            = nil
        FileChooser.display_mode_type       = nil
        _curr_modes["filemanager"]          = nil
        logger.dbg("auto-classic: classic for", path)
    else
        -- Restore Mosaic functions
        FileChooser.updateItems             = _mosaic_updateItems
        FileChooser._recalculateDimen       = _mosaic_recalcDimen
        FileChooser._updateItemsBuildUI     = _mosaic_updateItemsBuildUI
        FileChooser._do_cover_images        = true
        FileChooser._do_center_partial_rows = false
        FileChooser.display_mode            = MOSAIC_MODE
        FileChooser.display_mode_type       = "mosaic"
        _curr_modes["filemanager"]          = MOSAIC_MODE
        logger.dbg("auto-classic: mosaic for", path)
    end
end

-- ── hook into genItemTableFromPath ────────────────────────────────────────────

local orig_genItemTableFromPath = FileChooser.genItemTableFromPath
function FileChooser:genItemTableFromPath(path, ...)
    applyModeForPath(self, path)
    return orig_genItemTableFromPath(self, path, ...)
end

logger.info("auto-classic: patch applied")
