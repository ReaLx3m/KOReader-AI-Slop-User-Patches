--[[
User patch: Multiview
Automatically switches the file browser display mode based on folder contents.

  - Folders containing sub-folders  → configurable mode  (default: Classic)
  - Folders with only files         → configurable mode  (default: Mosaic)

Adds to the File Manager menu (filing-cabinet icon):
  AI Slop Settings → Multiview

Remembers scroll position per folder.

Installation:
  Copy to:  koreader/patches/2-multiview.lua

--]]

local userpatch            = require("userpatch")
local FileChooser          = require("ui/widget/filechooser")
local FileManagerMenu      = require("apps/filemanager/filemanagermenu")
local FileManagerMenuOrder = require("ui/elements/filemanager_menu_order")
local lfs                  = require("libs/libkoreader-lfs")
local logger               = require("logger")
local UIManager            = require("ui/uimanager")
local DoubleSpinWidget     = require("ui/widget/doublespinwidget")
local SpinWidget           = require("ui/widget/spinwidget")
local _                    = require("gettext")
local T                    = require("ffi/util").template

-- ── guard ─────────────────────────────────────────────────────────────────────

if FileChooser._multiview_patched then return end
FileChooser._multiview_patched = true

-- ── settings ──────────────────────────────────────────────────────────────────

local DEFAULTS = {
    enabled              = true,
    dirs_mode            = "classic",
    dirs_cols_portrait   = 3,
    dirs_rows_portrait   = 3,
    dirs_cols_landscape  = 4,
    dirs_rows_landscape  = 2,
    dirs_items_per_page  = 14,
    files_mode           = "mosaic_image",
    files_cols_portrait  = 2,
    files_rows_portrait  = 2,
    files_cols_landscape = 3,
    files_rows_landscape = 2,
    files_items_per_page = 14,
}

local function get(key)
    local cfg = G_reader_settings:readSetting("multiview") or {}
    local v = cfg[key]
    return (v == nil) and DEFAULTS[key] or v
end

local function set(key, value)
    local cfg = G_reader_settings:readSetting("multiview") or {}
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
        if f ~= "." and f ~= ".." and f:sub(-4) ~= ".sdr" then
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
local _settings_changed = false

local function applyMosaic(fc, mode, cp, rp, cl, rl)
    FileChooser.updateItems             = _mosaic_updateItems
    FileChooser._recalculateDimen       = _mosaic_recalcDimen
    FileChooser._updateItemsBuildUI     = _mosaic_updateItemsBuildUI
    FileChooser._do_cover_images        = true
    FileChooser._do_center_partial_rows = false
    FileChooser.display_mode            = mode
    FileChooser.display_mode_type       = "mosaic"
    _curr_modes["filemanager"]          = mode
    FileChooser.items_per_page          = nil
    local targets = { FileChooser }
    if fc and fc ~= FileChooser then targets[2] = fc end
    for _, t in ipairs(targets) do
        t.nb_cols_portrait  = cp
        t.nb_rows_portrait  = rp
        t.nb_cols_landscape = cl
        t.nb_rows_landscape = rl
    end
end

local function applyClassic(fc, items_per_page)
    FileChooser.updateItems         = _orig_updateItems
    FileChooser._recalculateDimen   = _orig_recalcDimen
    FileChooser.onCloseWidget       = _orig_onClose
    FileChooser._updateItemsBuildUI = nil
    FileChooser._do_cover_images    = nil
    FileChooser.display_mode        = nil
    FileChooser.display_mode_type   = nil
    _curr_modes["filemanager"]      = nil
    if items_per_page then
        FileChooser.items_per_page = items_per_page
        if fc and fc ~= FileChooser then fc.items_per_page = items_per_page end
    end
end

local function applyModeForPath(fc, path)
    if not get("enabled") then return end
    if not setupUpvalues(fc) then return end
    local has_dirs = pathHasSubdirs(path)
    if not _settings_changed and path == _last_path and has_dirs == _last_has_dirs then return end
    _last_path, _last_has_dirs = path, has_dirs
    _settings_changed = false
    local prefix = has_dirs and "dirs" or "files"
    local mode   = get(prefix .. "_mode")
    if mode == "classic" or mode == nil or mode == "" then
        applyClassic(fc, get(prefix .. "_items_per_page"))
    else
        applyMosaic(fc, mode,
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
    _last_path = nil; _settings_changed = true
    applyModeForPath(self, self.path)
    local saved = _saved_pages[self.path]
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

local function gridEntry(label, prefix, orientation, fc)
    local ck = prefix .. "_cols_" .. orientation
    local rk = prefix .. "_rows_" .. orientation
    return {
        text_func = function()
            return T(_("%1: %2 × %3"), label, get(ck), get(rk))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local orig_cols = get(ck)
            local orig_rows = get(rk)
            local cur_cols  = orig_cols
            local cur_rows  = orig_rows
            UIManager:show(DoubleSpinWidget:new{
                title_text          = label,
                width_factor        = 0.6,
                left_text           = _("Columns"),
                left_value          = orig_cols,
                left_min = 1, left_max = 8, left_default = 3,
                left_precision      = "%01d",
                right_text          = _("Rows"),
                right_value         = orig_rows,
                right_min = 1, right_max = 8, right_default = 3,
                right_precision     = "%01d",
                keep_shown_on_apply = true,
                -- Live preview on Apply
                callback = function(lv, rv)
                    cur_cols = lv; cur_rows = rv
                    if fc and get("enabled") then
                        local is_portrait = fc.portrait_mode ~= false
                        if orientation == (is_portrait and "portrait" or "landscape") then
                            if orientation == "portrait" then
                                fc.nb_cols_portrait = lv
                                fc.nb_rows_portrait = rv
                            else
                                fc.nb_cols_landscape = lv
                                fc.nb_rows_landscape = rv
                            end
                            fc.no_refresh_covers = true
                            fc:updateItems()
                        end
                    end
                end,
                -- Persist and re-apply correct mode on dismiss
                close_callback = function()
                    if cur_cols ~= orig_cols or cur_rows ~= orig_rows then
                        set(ck, cur_cols)
                        set(rk, cur_rows)
                    end
                    _last_path = nil; _last_has_dirs = nil; _settings_changed = true
                    if fc and get("enabled") then
                        applyModeForPath(fc, fc.path)
                        fc.no_refresh_covers = nil
                        fc:updateItems()
                    end
                    touchmenu_instance:updateItems()
                end,
            })
        end,
    }
end

local function contextSubMenu(prefix, section_label, fc)
    local t = {}
    for _, v in ipairs(MODE_OPTIONS) do
        local label, mode_key = v[1], v[2]
        table.insert(t, {
            text = label,
            radio = true,
            checked_func = function() return get(prefix .. "_mode") == mode_key end,
            callback = function(touchmenu_instance)
                set(prefix .. "_mode", mode_key)
                _last_path = nil; _last_has_dirs = nil; _settings_changed = true
                touchmenu_instance:updateItems()
                if fc and get("enabled") then
                    applyModeForPath(fc, fc.path)
                    fc.no_refresh_covers = nil; fc:updateItems()
                end
            end,
        })
    end
    t[#t].separator = true
    table.insert(t, {
        text_func = function()
            return T(_("Items per page (classic): %1"), get(prefix .. "_items_per_page"))
        end,
        enabled_func = function()
            local m = get(prefix .. "_mode")
            return m == "classic" or m == nil or m == ""
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            UIManager:show(SpinWidget:new{
                title_text        = T(_("%1 – items per page (classic)"), section_label),
                value             = get(prefix .. "_items_per_page"),
                value_min = 4, value_max = 40, value_step = 1, default_value = 14,
                keep_shown_on_apply = true,
                callback = function(spin)
                    set(prefix .. "_items_per_page", spin.value)
                    _last_path = nil; _settings_changed = true
                    touchmenu_instance:updateItems()
                    if fc and get("enabled") then
                        local m = get(prefix .. "_mode")
                        if m == "classic" or m == nil or m == "" then
                            FileChooser.items_per_page = spin.value
                            fc.no_refresh_covers = nil; fc:updateItems()
                        end
                    end
                end,
            })
        end,
    })
    table.insert(t, gridEntry(T(_("%1 portrait grid"),  section_label), prefix, "portrait",  fc))
    table.insert(t, gridEntry(T(_("%1 landscape grid"), section_label), prefix, "landscape", fc))
    return t
end

-- ── patch setUpdateItemTable ──────────────────────────────────────────────────

local orig_setUpdateItemTable = FileManagerMenu.setUpdateItemTable

function FileManagerMenu:setUpdateItemTable()
    local fc = self.ui and self.ui.file_chooser

    -- Inject "ai_slop_settings" into the filing-cabinet Settings tab once.
    if type(FileManagerMenuOrder.filemanager_settings) == "table" then
        local found = false
        for _, k in ipairs(FileManagerMenuOrder.filemanager_settings) do
            if k == "ai_slop_settings" then found = true; break end
        end
        if not found then
            table.insert(FileManagerMenuOrder.filemanager_settings, 1, "ai_slop_settings")
        end
    end

    -- "AI Slop Settings" parent entry (shared across patches — only define once).
    if not self.menu_items.ai_slop_settings then
        self.menu_items.ai_slop_settings = {
            text = "AI Slop Settings",
            sub_item_table = {},
        }
    end

    -- Append Multiview sub-entry (guard against duplicate injection).
    local already = false
    for _, item in ipairs(self.menu_items.ai_slop_settings.sub_item_table) do
        if item._multiview_entry then already = true; break end
    end
    if not already then
        table.insert(self.menu_items.ai_slop_settings.sub_item_table, {
            _multiview_entry = true,
            text = _("Multiview"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Multiview"),
                        checked_func = function() return get("enabled") == true end,
                        callback = function(touchmenu_instance)
                            set("enabled", not get("enabled"))
                            _last_path = nil; _last_has_dirs = nil; _settings_changed = true
                            touchmenu_instance:updateItems()
                            if fc then
                                applyModeForPath(fc, fc.path)
                                fc.no_refresh_covers = nil; fc:updateItems()
                            end
                        end,
                    },
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
        })
    end

    orig_setUpdateItemTable(self)
end

logger.info("multiview: patch applied")
