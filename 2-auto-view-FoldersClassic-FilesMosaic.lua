--[[
User patch: Automatically switch display mode based on folder contents.

  - Folders containing subfolders  → Classic (filename list) view
  - Pure-file folders              → Mosaic view (default grid)

Remembers scroll position per folder so navigating back lands on the
same page you left on.

Installation:
  Copy this file to:  koreader/patches/2-auto-classic-mode.lua

Customise the constant below if needed.
--]]

local MOSAIC_MODE = "mosaic_image"

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
local _last_path
local _last_has_dirs

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
    local has_dirs = pathHasSubdirs(path)
    if path == _last_path and has_dirs == _last_has_dirs then return end
    _last_path     = path
    _last_has_dirs = has_dirs

    if has_dirs then
        -- Classic (plain list) view
        FileChooser.updateItems             = _orig_updateItems
        FileChooser._recalculateDimen       = _orig_recalcDimen
        FileChooser.onCloseWidget           = _orig_onClose
        FileChooser._updateItemsBuildUI     = nil
        FileChooser._do_cover_images        = nil
        FileChooser.display_mode            = nil
        FileChooser.display_mode_type       = nil
        _curr_modes["filemanager"]          = nil
    else
        -- Mosaic view
        FileChooser.updateItems             = _mosaic_updateItems
        FileChooser._recalculateDimen       = _mosaic_recalcDimen
        FileChooser._updateItemsBuildUI     = _mosaic_updateItemsBuildUI
        FileChooser._do_cover_images        = true
        FileChooser._do_center_partial_rows = false
        FileChooser.display_mode            = MOSAIC_MODE
        FileChooser.display_mode_type       = "mosaic"
        _curr_modes["filemanager"]          = MOSAIC_MODE
    end
end

-- ── per-path scroll memory ────────────────────────────────────────────────────

local _saved_pages          = {}
local _restore_page_pending = false
local _restore_for_path     = nil

local orig_changeToPath = FileChooser.changeToPath
function FileChooser:changeToPath(path, focused_path)
    if self.path then
        _saved_pages[self.path] = self.page or 1
    end
    _restore_page_pending = true
    local resolved = path
    if path then
        resolved = path:gsub("/[^/]+/%.%.$", ""):gsub("/%.%.$", "")
        if resolved == "" then resolved = "/" end
    end
    _restore_for_path = resolved
    return orig_changeToPath(self, path, focused_path)
end

-- Defined AFTER applyModeForPath to avoid a forward-reference error.
local orig_switchItemTable = FileChooser.switchItemTable
function FileChooser:switchItemTable(title, item_table, item_number, ...)
    orig_switchItemTable(self, title, item_table, item_number, ...)

    if not _restore_page_pending then return end
    if self.path ~= _restore_for_path then return end
    _restore_page_pending = false
    _restore_for_path     = nil

    -- Re-apply the correct mode for the destination now that all cover scans
    -- are done, in case they left the mode in the wrong state.
    _last_path = nil
    applyModeForPath(self, self.path)

    local saved  = _saved_pages[self.path]
    if not saved then return end
    local total  = self.page_num or 1
    local target = math.max(1, math.min(saved, total))
    if self.page ~= target then
        self.page = target
        self:updateItems()
    end
end

-- ── hook into genItemTableFromPath ────────────────────────────────────────────

local orig_genItemTableFromPath = FileChooser.genItemTableFromPath
function FileChooser:genItemTableFromPath(path, ...)
    applyModeForPath(self, path)
    return orig_genItemTableFromPath(self, path, ...)
end

logger.info("auto-classic: patch applied")
