--[[
User patch: Multiview Smart
Automatically switches the file browser display mode and grid size based on
folder contents.

  - Folders containing sub-folders  → configurable mode  (default: Classic)
  - Folders with only files         → configurable mode  (default: Mosaic)

Grid size is chosen dynamically: counts items in the folder, then picks the
smallest enabled grid whose area fits the count, within the configured min/max
range. Portrait and landscape grids are configured independently.

Remembers scroll position per folder.

Installation:
  Copy to:  koreader/patches/2-multiview-smart.lua

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

-- ── guard ─────────────────────────────────────────────────────────────────────

if FileChooser._multiview_smart_patched then return end
FileChooser._multiview_smart_patched = true

-- ── settings ──────────────────────────────────────────────────────────────────

local DEFAULTS = {
    enabled  = true,
    -- mode per context (dirs = folder has subdirs, files = folder has only files)
    dirs_mode  = "classic",
    files_mode = "mosaic_image",
    -- smart grid: mosaic min/max per context+orientation
    dirs_sg_portrait_mosaic_min_cols      = 3,
    dirs_sg_portrait_mosaic_min_rows      = 3,
    dirs_sg_portrait_mosaic_max_cols      = 4,
    dirs_sg_portrait_mosaic_max_rows      = 4,
    dirs_sg_landscape_mosaic_min_cols     = 3,
    dirs_sg_landscape_mosaic_min_rows     = 3,
    dirs_sg_landscape_mosaic_max_cols     = 4,
    dirs_sg_landscape_mosaic_max_rows     = 4,
    dirs_sg_portrait_classic_min_items    = 8,
    dirs_sg_portrait_classic_max_items    = 16,
    files_sg_portrait_mosaic_min_cols     = 2,
    files_sg_portrait_mosaic_min_rows     = 2,
    files_sg_portrait_mosaic_max_cols     = 3,
    files_sg_portrait_mosaic_max_rows     = 3,
    files_sg_landscape_mosaic_min_cols    = 2,
    files_sg_landscape_mosaic_min_rows    = 2,
    files_sg_landscape_mosaic_max_cols    = 3,
    files_sg_landscape_mosaic_max_rows    = 3,
    files_sg_portrait_classic_min_items   = 8,
    files_sg_portrait_classic_max_items   = 16,
}

local SETTINGS_KEY = "multiview_smart"

local function get(key)
    local cfg = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    local v = cfg[key]
    return (v == nil) and DEFAULTS[key] or v
end

local function set(key, value)
    local cfg = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    cfg[key] = value
    G_reader_settings:saveSetting(SETTINGS_KEY, cfg)
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

-- ── directory / item detection ────────────────────────────────────────────────

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

local function countItems(path, count_dirs)
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok then return 0 end
    local n = 0
    for f in iter, dir_obj do
        if f ~= "." and f ~= ".." and f:sub(-4) ~= ".sdr" then
            if FileChooser.show_hidden or f:sub(1,1) ~= "." then
                local attr = lfs.attributes(path .. "/" .. f)
                if attr then
                    if count_dirs and attr.mode == "directory" then n = n + 1
                    elseif not count_dirs and attr.mode == "file" then n = n + 1
                    end
                end
            end
        end
    end
    return n
end

-- ── grid enumeration and selection ────────────────────────────────────────────

-- Portrait: square or one-wider-than-tall  (3×3, 4×3, 4×4, 5×4 …)
-- Landscape: square or one-taller-than-wide (3×3, 3×4, 4×4, 4×5 …)
local function enumGrids(min_cols, min_rows, max_cols, max_rows, orient)
    local grids = {}
    for c = min_cols, max_cols do
        for r = min_rows, max_rows do
            local ok
            if orient == "portrait" then
                ok = (c >= r) and (c <= r + 1)
            elseif orient == "landscape" then
                ok = (r >= c) and (r <= c + 1)
            else
                ok = true
            end
            if ok then
                table.insert(grids, { c = c, r = r, area = c * r })
            end
        end
    end
    table.sort(grids, function(a, b)
        if a.area ~= b.area then return a.area < b.area end
        return a.c < b.c
    end)
    return grids
end

local function gridKey(prefix, orient, c, r)
    return prefix .. "_sg_" .. orient .. "_grid_" .. c .. "x" .. r
end

-- Pick the smallest enabled grid whose area >= n. Falls back to largest enabled.
local function smartGrid(n, prefix, orient, min_cols, min_rows, max_cols, max_rows)
    local grids = enumGrids(min_cols, min_rows, max_cols, max_rows, orient)
    local fallback_c, fallback_r = max_cols, max_rows
    for _, g in ipairs(grids) do
        local key = gridKey(prefix, orient, g.c, g.r)
        -- nil/absent = included, true = excluded
        if get(key) ~= true then
            fallback_c, fallback_r = g.c, g.r
            if g.area >= n then return g.c, g.r end
        end
    end
    return fallback_c, fallback_r
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
    local n = has_dirs
        and (countItems(path, true) + countItems(path, false))
        or  countItems(path, false)
    if mode == "classic" or mode == nil or mode == "" then
        local min_i = get(prefix .. "_sg_portrait_classic_min_items")
        local max_i = get(prefix .. "_sg_portrait_classic_max_items")
        applyClassic(fc, math.max(min_i, math.min(max_i, n)))
    else
        local p_cols, p_rows = smartGrid(n, prefix, "portrait",
            get(prefix .. "_sg_portrait_mosaic_min_cols"),
            get(prefix .. "_sg_portrait_mosaic_min_rows"),
            get(prefix .. "_sg_portrait_mosaic_max_cols"),
            get(prefix .. "_sg_portrait_mosaic_max_rows"))
        local l_cols, l_rows = smartGrid(n, prefix, "landscape",
            get(prefix .. "_sg_landscape_mosaic_min_cols"),
            get(prefix .. "_sg_landscape_mosaic_min_rows"),
            get(prefix .. "_sg_landscape_mosaic_max_cols"),
            get(prefix .. "_sg_landscape_mosaic_max_rows"))
        applyMosaic(fc, mode, p_cols, p_rows, l_cols, l_rows)
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

-- ── helpers ───────────────────────────────────────────────────────────────────

local function refresh(fc)
    if fc and get("enabled") then
        fc.no_refresh_covers = nil
        fc:updateItems()
    end
end

local function sgChanged(fc)
    _last_path = nil; _last_has_dirs = nil; _settings_changed = true
    applyModeForPath(fc, fc.path)
    refresh(fc)
end

-- ── include/exclude grid checklist ────────────────────────────────────────────

local function sgIncludeExcludeMenu(prefix, orient, fc)
    local min_cols = get(prefix .. "_sg_" .. orient .. "_mosaic_min_cols")
    local min_rows = get(prefix .. "_sg_" .. orient .. "_mosaic_min_rows")
    local max_cols = get(prefix .. "_sg_" .. orient .. "_mosaic_max_cols")
    local max_rows = get(prefix .. "_sg_" .. orient .. "_mosaic_max_rows")
    local grids    = enumGrids(min_cols, min_rows, max_cols, max_rows, orient)
    local items    = {}
    for _, g in ipairs(grids) do
        local is_min = (g.c == min_cols and g.r == min_rows)
        local is_max = (g.c == max_cols and g.r == max_rows)
        local key    = gridKey(prefix, orient, g.c, g.r)
        local label  = g.c .. "×" .. g.r
        if is_min or is_max then
            table.insert(items, {
                text         = label .. (is_min and " (min)" or " (max)"),
                checked_func = function() return true end,
                enabled_func = function() return false end,
                callback     = function() end,
            })
        else
            table.insert(items, {
                text = label,
                checked_func = function() return get(key) ~= true end,
                callback = function(touchmenu_instance)
                    set(key, get(key) ~= true and true or nil)
                    _last_path = nil; _last_has_dirs = nil; _settings_changed = true
                    touchmenu_instance:updateItems()
                    if fc and get("enabled") then
                        UIManager:nextTick(function()
                            applyModeForPath(fc, fc.path)
                            refresh(fc)
                        end)
                    end
                end,
            })
        end
    end
    if #items == 0 then
        return {{ text = "(min and max are the same grid)", enabled_func = function() return false end, callback = function() end }}
    end
    return items
end

-- ── inline settings items for one context+orientation ─────────────────────────

local function sgInlineItems(prefix, ctx_label, orient, orient_label, def_min_c, def_min_r, def_max_c, def_max_r, fc)
    local p = prefix .. "_sg_" .. orient .. "_mosaic_"
    return {
        {
            text_func = function()
                return orient_label .. " min: "
                    .. get(p .. "min_cols") .. "×" .. get(p .. "min_rows")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local cur_cols = get(p .. "min_cols")
                local cur_rows = get(p .. "min_rows")
                UIManager:show(DoubleSpinWidget:new{
                    title_text      = ctx_label .. " " .. orient_label .. " min grid",
                    width_factor    = 0.6,
                    left_text       = _("Columns"),
                    left_value      = cur_cols,
                    left_min = 1, left_max = 8, left_default = def_min_c,
                    left_precision  = "%01d",
                    right_text      = _("Rows"),
                    right_value     = cur_rows,
                    right_min = 1, right_max = 8, right_default = def_min_r,
                    right_precision = "%01d",
                    keep_shown_on_apply = true,
                    callback = function(lv, rv)
                        cur_cols = lv; cur_rows = rv
                        set(p .. "min_cols", cur_cols)
                        set(p .. "min_rows", cur_rows)
                        if fc then sgChanged(fc) end
                    end,
                    close_callback = function()
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
        },
        {
            text_func = function()
                return orient_label .. " max: "
                    .. get(p .. "max_cols") .. "×" .. get(p .. "max_rows")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local cur_cols = get(p .. "max_cols")
                local cur_rows = get(p .. "max_rows")
                UIManager:show(DoubleSpinWidget:new{
                    title_text      = ctx_label .. " " .. orient_label .. " max grid",
                    width_factor    = 0.6,
                    left_text       = _("Columns"),
                    left_value      = cur_cols,
                    left_min = 1, left_max = 8, left_default = def_max_c,
                    left_precision  = "%01d",
                    right_text      = _("Rows"),
                    right_value     = cur_rows,
                    right_min = 1, right_max = 8, right_default = def_max_r,
                    right_precision = "%01d",
                    keep_shown_on_apply = true,
                    callback = function(lv, rv)
                        cur_cols = lv; cur_rows = rv
                        set(p .. "max_cols", cur_cols)
                        set(p .. "max_rows", cur_rows)
                        if fc then sgChanged(fc) end
                    end,
                    close_callback = function()
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
        },
        {
            text_func = function()
                if get(p .. "min_cols") == get(p .. "max_cols")
                and get(p .. "min_rows") == get(p .. "max_rows") then
                    return orient_label .. " grids (none — min=max)"
                end
                return orient_label .. " grids"
            end,
            enabled_func = function()
                return not (get(p .. "min_cols") == get(p .. "max_cols")
                        and get(p .. "min_rows") == get(p .. "max_rows"))
            end,
            sub_item_table_func = function()
                return sgIncludeExcludeMenu(prefix, orient, fc)
            end,
        },
    }
end

-- ── classic items spinner ─────────────────────────────────────────────────────

local function sgClassicSpinner(label, key_min, key_max, fc)
    local function spinner(title, key, default, touchmenu_instance)
        UIManager:show(SpinWidget:new{
            title_text          = title,
            value               = get(key),
            value_min = 1, value_max = 40, value_step = 1, default_value = default,
            keep_shown_on_apply = true,
            callback = function(spin)
                set(key, spin.value)
                touchmenu_instance:updateItems()
                if fc then sgChanged(fc) end
            end,
        })
    end
    return {
        {
            text_func      = function() return "Classic min: " .. get(key_min) end,
            keep_menu_open = true,
            callback       = function(tmi) spinner(label .. " classic min items", key_min, 8,  tmi) end,
        },
        {
            text_func      = function() return "Classic max: " .. get(key_max) end,
            keep_menu_open = true,
            callback       = function(tmi) spinner(label .. " classic max items", key_max, 16, tmi) end,
        },
    }
end

-- ── main menu ─────────────────────────────────────────────────────────────────

local MODE_OPTIONS = {
    { _("Classic (filename list)"),  "classic"      },
    { _("Mosaic with cover images"), "mosaic_image" },
}

local function modeEntry(prefix, label, fc)
    local entries = {}
    for _, v in ipairs(MODE_OPTIONS) do
        local text, mode_key = v[1], v[2]
        table.insert(entries, {
            text = text,
            radio = true,
            checked_func = function() return get(prefix .. "_mode") == mode_key end,
            callback = function(touchmenu_instance)
                set(prefix .. "_mode", mode_key)
                touchmenu_instance:updateItems()
                if fc then sgChanged(fc) end
            end,
        })
    end
    return entries
end

local function contextMenu(prefix, ctx_label, def_min_c, def_min_r, def_max_c, def_max_r, fc)
    local t = {}
    for _, e in ipairs(modeEntry(prefix, ctx_label, fc)) do table.insert(t, e) end
    t[#t].separator = true
    for _, item in ipairs(sgInlineItems(prefix, ctx_label, "portrait",  "portrait",  def_min_c, def_min_r, def_max_c, def_max_r, fc)) do table.insert(t, item) end
    for _, item in ipairs(sgInlineItems(prefix, ctx_label, "landscape", "landscape", def_min_c, def_min_r, def_max_c, def_max_r, fc)) do table.insert(t, item) end
    for _, item in ipairs(sgClassicSpinner(ctx_label,
        prefix .. "_sg_portrait_classic_min_items",
        prefix .. "_sg_portrait_classic_max_items", fc)) do table.insert(t, item) end
    return t
end

local function buildMenu(fc)
    return {
        {
            text = "Multiview Smart",
            checked_func = function() return get("enabled") == true end,
            callback = function(touchmenu_instance)
                set("enabled", not get("enabled"))
                _last_path = nil; _last_has_dirs = nil; _settings_changed = true
                touchmenu_instance:updateItems()
                if fc then
                    UIManager:nextTick(function()
                        applyModeForPath(fc, fc.path)
                        refresh(fc)
                    end)
                end
            end,
        },
        {
            text = "Folder Mode",
            sub_item_table_func = function()
                return contextMenu("dirs", "Folders", 3, 3, 4, 4, fc)
            end,
        },
        {
            text = "File Mode",
            sub_item_table_func = function()
                return contextMenu("files", "Files", 2, 2, 3, 3, fc)
            end,
        },
    }
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

    -- Append the Multiview Smart sub-entry (guard against duplicate injection).
    local already = false
    for _, item in ipairs(self.menu_items.ai_slop_settings.sub_item_table) do
        if item._multiview_smart_entry then already = true; break end
    end
    if not already then
        table.insert(self.menu_items.ai_slop_settings.sub_item_table, {
            _multiview_smart_entry = true,
            text = "Multiview Smart",
            sub_item_table_func = function()
                return buildMenu(fc)
            end,
        })
    end

    orig_setUpdateItemTable(self)
end

logger.info("multiview-smart: patch applied")
