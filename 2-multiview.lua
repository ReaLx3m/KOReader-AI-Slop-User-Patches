--[[
User patch: Multiview
Automatically switches the file browser display mode based on folder contents.

  - Folders containing sub-folders  → configurable mode  (default: Classic)
  - Folders with only files         → configurable mode  (default: Mosaic)

Adds to the File Manager menu (filing-cabinet icon):
  • Display mode  → "Multiview"          (toggle with checkmark)
  • Settings      → "Multiview Settings" (mode + grid per context)

Remembers scroll position per folder.

Installation:
  Copy to:  koreader/patches/2-multiview.lua
--]]

local userpatch          = require("userpatch")
local FileChooser        = require("ui/widget/filechooser")
local FileManagerMenu    = require("apps/filemanager/filemanagermenu")
local FileManagerMenuOrder = require("ui/elements/filemanager_menu_order")
local lfs                = require("libs/libkoreader-lfs")
local logger             = require("logger")
local UIManager          = require("ui/uimanager")
local DoubleSpinWidget   = require("ui/widget/doublespinwidget")
local SpinWidget         = require("ui/widget/spinwidget")
local _                  = require("gettext")
local T                  = require("ffi/util").template

-- ── guard ─────────────────────────────────────────────────────────────────────

if FileChooser._multiview_patched then return end
FileChooser._multiview_patched = true

-- ── settings (stored in G_reader_settings like the titlebar patch) ────────────

local DEFAULTS = {
    enabled               = true,
    dirs_mode             = "classic",
    dirs_cols_portrait    = 3,
    dirs_rows_portrait    = 3,
    dirs_cols_landscape   = 4,
    dirs_rows_landscape   = 2,
    dirs_items_per_page   = 14,
    files_mode            = "mosaic_image",
    files_cols_portrait   = 2,
    files_rows_portrait   = 2,
    files_cols_landscape  = 3,
    files_rows_landscape  = 2,
    files_items_per_page  = 14,
}

local function get(key)
    local cfg = G_reader_settings:readSetting("multiview", DEFAULTS)
    local v = cfg[key]
    return (v == nil) and DEFAULTS[key] or v
end

local function set(key, value)
    local cfg = G_reader_settings:readSetting("multiview", DEFAULTS)
    cfg[key] = value
    G_reader_settings:saveSetting("multiview", cfg)
end

-- ── coverbrowser upvalue cache ────────────────────────────────────────────────

local _ready = false
local _curr_modes
local _orig_updateItems, _orig_recalcDimen, _orig_onClose
local _mosaic_updateItems, _mosaic_recalcDimen, _mosaic_updateItemsBuildUI

local function setupUpvalues(fc)
    if _ready then return true end
    local cb = fc.show_parent and fc.show_parent.coverbrowser
    if not cb or not cb.setupFileManagerDisplayMode then return false end
    local fn          = cb.setupFileManagerDisplayMode
    _curr_modes       = userpatch.getUpValue(fn, "curr_display_modes")
    _orig_updateItems = userpatch.getUpValue(fn, "_FileChooser_updateItems_orig")
    _orig_recalcDimen = userpatch.getUpValue(fn, "_FileChooser__recalculateDimen_orig")
    _orig_onClose     = userpatch.getUpValue(fn, "_FileChooser_onCloseWidget_orig")
    if not _curr_modes or not _orig_updateItems then return false end
    _mosaic_updateItems        = FileChooser.updateItems
    _mosaic_recalcDimen        = FileChooser._recalculateDimen
    _mosaic_updateItemsBuildUI = FileChooser._updateItemsBuildUI
    _ready = true
    return true
end

-- ── directory detection ───────────────────────────────────────────────────────

local function pathHasSubdirs(path)
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok then return false end
    for f in iter, dir_obj do
        if f ~= "." and f ~= ".." then
            if FileChooser.show_hidden or f:sub(1,1) ~= "." then
                local attr = lfs.attributes(path .. "/" .. f)
                if attr and attr.mode == "directory" then return true end
            end
        end
    end
    return false
end

-- ── mode application ──────────────────────────────────────────────────────────

local _last_path
local _last_has_dirs

local function applyClassic(items_per_page)
    FileChooser.updateItems         = _orig_updateItems
    FileChooser._recalculateDimen   = _orig_recalcDimen
    FileChooser.onCloseWidget       = _orig_onClose
    FileChooser._updateItemsBuildUI = nil
    FileChooser._do_cover_images    = nil
    FileChooser.display_mode        = nil
    FileChooser.display_mode_type   = nil
    _curr_modes["filemanager"]      = nil
    -- Apply the per-context items-per-page for classic mode.
    -- FileChooser.perpage is read by Menu._recalculateDimen on next layout.
    if items_per_page then
        FileChooser.items_per_page = items_per_page
    end
end

local function applyMosaic(mode, cp, rp, cl, rl)
    FileChooser.updateItems             = _mosaic_updateItems
    FileChooser._recalculateDimen       = _mosaic_recalcDimen
    FileChooser._updateItemsBuildUI     = _mosaic_updateItemsBuildUI
    FileChooser._do_cover_images        = true
    FileChooser._do_center_partial_rows = false
    FileChooser.display_mode            = mode
    FileChooser.display_mode_type       = "mosaic"
    _curr_modes["filemanager"]          = mode
    FileChooser.nb_cols_portrait        = cp
    FileChooser.nb_rows_portrait        = rp
    FileChooser.nb_cols_landscape       = cl
    FileChooser.nb_rows_landscape       = rl
    -- Clear any items_per_page we set during classic mode so mosaic layout
    -- is not affected. Mosaic uses nb_cols/nb_rows, not items_per_page.
    FileChooser.items_per_page          = nil
end

local function applyModeForPath(fc, path)
    if not get("enabled") then return end
    if not setupUpvalues(fc) then return end
    local has_dirs = pathHasSubdirs(path)
    if path == _last_path and has_dirs == _last_has_dirs then return end
    _last_path, _last_has_dirs = path, has_dirs
    local prefix = has_dirs and "dirs" or "files"
    local mode   = get(prefix .. "_mode")
    if mode == "classic" or mode == nil or mode == "" then
        applyClassic(get(prefix .. "_items_per_page"))
    else
        applyMosaic(mode,
            get(prefix .. "_cols_portrait"),
            get(prefix .. "_rows_portrait"),
            get(prefix .. "_cols_landscape"),
            get(prefix .. "_rows_landscape"))
    end
end

-- ── per-path scroll memory ────────────────────────────────────────────────────

local _saved_pages          = {}
local _restore_page_pending = false
local _restore_for_path     = nil

local orig_changeToPath = FileChooser.changeToPath
function FileChooser:changeToPath(path, focused_path)
    if self.path then _saved_pages[self.path] = self.page or 1 end
    _restore_page_pending = true
    local resolved = path
    if path then
        resolved = path:gsub("/[^/]+/%.%.$", ""):gsub("/%.%.$", "")
        if resolved == "" then resolved = "/" end
    end
    _restore_for_path = resolved
    return orig_changeToPath(self, path, focused_path)
end

local orig_switchItemTable = FileChooser.switchItemTable
function FileChooser:switchItemTable(title, item_table, item_number, ...)
    orig_switchItemTable(self, title, item_table, item_number, ...)
    if not _restore_page_pending then return end
    if self.path ~= _restore_for_path then return end
    _restore_page_pending, _restore_for_path = false, nil
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

local orig_genItemTableFromPath = FileChooser.genItemTableFromPath
function FileChooser:genItemTableFromPath(path, ...)
    -- CoverBrowser calls genItemTableFromPath for individual file items during
    -- cover scanning, passing the file's own path. We only want to switch mode
    -- when entering an actual directory, so skip non-directory paths.
    local attr = lfs.attributes(path)
    if attr and attr.mode == "directory" then
        applyModeForPath(self, path)
    end
    return orig_genItemTableFromPath(self, path, ...)
end

-- ── menu ──────────────────────────────────────────────────────────────────────

local MODE_OPTIONS = {
    { _("Classic (filename list)"),  "classic"      },
    { _("Mosaic with cover images"), "mosaic_image" },
}

local function modeLabel(prefix)
    local m = get(prefix .. "_mode")
    if m == "classic" or m == nil or m == "" then return _("Classic") end
    return T(_("Mosaic %1×%2"),
        get(prefix .. "_cols_portrait"),
        get(prefix .. "_rows_portrait"))
end

local function gridEntry(label, prefix, orientation)
    local ck = prefix .. "_cols_" .. orientation
    local rk = prefix .. "_rows_" .. orientation
    return {
        text_func = function()
            return T(_("%1: %2 × %3"), label, get(ck), get(rk))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            UIManager:show(DoubleSpinWidget:new{
                title_text          = label,
                width_factor        = 0.6,
                left_text           = _("Columns"),
                left_value          = get(ck),
                left_min = 1, left_max = 8, left_default = 3,
                left_precision      = "%01d",
                right_text          = _("Rows"),
                right_value         = get(rk),
                right_min = 1, right_max = 8, right_default = 3,
                right_precision     = "%01d",
                keep_shown_on_apply = true,
                callback = function(lv, rv)
                    set(ck, lv)
                    set(rk, rv)
                    _last_path = nil
                    touchmenu_instance:updateItems()
                end,
            })
        end,
    }
end

-- Build the mode-picker + grid sub-table for one context
local function contextSubMenu(prefix, section_label, fc)
    local t = {}
    for _, v in ipairs(MODE_OPTIONS) do
        local label, mode_key = v[1], v[2]
        table.insert(t, {
            text = label,
            radio = true,
            checked_func = function()
                return get(prefix .. "_mode") == mode_key
            end,
            callback = function(touchmenu_instance)
                set(prefix .. "_mode", mode_key)
                _last_path = nil
                touchmenu_instance:updateItems()
                if fc and get("enabled") then
                    applyModeForPath(fc, fc.path)
                    fc:updateItems(1, true)
                end
            end,
        })
    end
    t[#t].separator = true
    -- Items per page — only relevant when classic mode is selected
    table.insert(t, {
        text_func = function()
            return T(_("Items per page (classic): %1"),
                get(prefix .. "_items_per_page"))
        end,
        enabled_func = function()
            local m = get(prefix .. "_mode")
            return m == "classic" or m == nil or m == ""
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            UIManager:show(SpinWidget:new{
                title_text  = T(_("%1 – items per page (classic)"), section_label),
                value       = get(prefix .. "_items_per_page"),
                value_min   = 4,
                value_max   = 40,
                value_step  = 1,
                default_value = 14,
                keep_shown_on_apply = true,
                callback    = function(spin)
                    set(prefix .. "_items_per_page", spin.value)
                    _last_path = nil
                    touchmenu_instance:updateItems()
                    if fc and get("enabled") then
                        local m = get(prefix .. "_mode")
                        if m == "classic" or m == nil or m == "" then
                            FileChooser.items_per_page = spin.value
                            fc:updateItems(1, true)
                        end
                    end
                end,
            })
        end,
    })
    table.insert(t, gridEntry(
        T(_("%1 portrait grid"),  section_label), prefix, "portrait"))
    table.insert(t, gridEntry(
        T(_("%1 landscape grid"), section_label), prefix, "landscape"))
    return t
end

-- ── patch setUpdateItemTable ──────────────────────────────────────────────────

local orig_setUpdateItemTable = FileManagerMenu.setUpdateItemTable

function FileManagerMenu:setUpdateItemTable()
    local fc = self.ui and self.ui.file_chooser

    -- Log all available FileManagerMenuOrder keys once so we can see what
    -- the real display-mode tab key is called on this build.
    if not FileManagerMenuOrder._multiview_logged then
        FileManagerMenuOrder._multiview_logged = true
        local keys = {}
        for k, v in pairs(FileManagerMenuOrder) do
            if type(v) == "table" then
                table.insert(keys, k .. "(" .. #v .. ")")
            end
        end
        table.sort(keys)
        logger.info("multiview: FileManagerMenuOrder keys = " .. table.concat(keys, ", "))
    end

    -- ── Display mode tab ─────────────────────────────────────────────────────
    -- The display-mode section key varies by build. Known names:
    --   "filemanager"         (older builds)
    --   "filemanager_display_mode" (some builds)
    -- We try each; whichever exists gets our "multiview" entry prepended.
    -- We also always inject into "filemanager_settings" for the Settings tab.
    local dm_key = nil
    for _, candidate in ipairs({ "filemanager", "filemanager_display_mode" }) do
        if type(FileManagerMenuOrder[candidate]) == "table" then
            dm_key = candidate
            break
        end
    end

    if dm_key then
        local found = false
        for _, k in ipairs(FileManagerMenuOrder[dm_key]) do
            if k == "multiview" then found = true; break end
        end
        if not found then
            table.insert(FileManagerMenuOrder[dm_key], 1, "multiview")
        end
    end

    -- ── Settings tab ─────────────────────────────────────────────────────────
    if type(FileManagerMenuOrder.filemanager_settings) == "table" then
        local found = false
        for _, k in ipairs(FileManagerMenuOrder.filemanager_settings) do
            if k == "multiview_settings" then found = true; break end
        end
        if not found then
            table.insert(FileManagerMenuOrder.filemanager_settings, 1, "multiview_settings")
        end
    end

    -- ── Define the menu entries on self.menu_items ───────────────────────────

    -- "Multiview" toggle — goes into Display mode tab if dm_key was found,
    -- otherwise falls back into Settings tab (added to filemanager_settings).
    if not dm_key then
        -- No display-mode tab found: add toggle to Settings as a fallback
        if type(FileManagerMenuOrder.filemanager_settings) == "table" then
            local found = false
            for _, k in ipairs(FileManagerMenuOrder.filemanager_settings) do
                if k == "multiview" then found = true; break end
            end
            if not found then
                table.insert(FileManagerMenuOrder.filemanager_settings, 1, "multiview")
            end
        end
    end

    self.menu_items.multiview = {
        text = _("Multiview"),
        checked_func = function()
            return get("enabled") == true
        end,
        callback = function(touchmenu_instance)
            set("enabled", not get("enabled"))
            _last_path = nil
            touchmenu_instance:updateItems()
            if fc then
                if get("enabled") then
                    applyModeForPath(fc, fc.path)
                end
                fc:updateItems(1, true)
            end
        end,
    }

    -- "Multiview Settings" sub-menu — always goes into Settings tab
    self.menu_items.multiview_settings = {
        text = _("Multiview Settings"),
        sub_item_table_func = function()
            return {
                {
                    text_func = function()
                        return T(_("Folders mode: %1"), modeLabel("dirs"))
                    end,
                    sub_item_table_func = function()
                        return contextSubMenu("dirs", _("Folders"), fc)
                    end,
                },
                {
                    text_func = function()
                        return T(_("Files mode: %1"), modeLabel("files"))
                    end,
                    sub_item_table_func = function()
                        return contextSubMenu("files", _("Files"), fc)
                    end,
                },
            }
        end,
    }

    -- Call the original AFTER we've set everything up
    orig_setUpdateItemTable(self)
end

logger.info("multiview: patch applied")
