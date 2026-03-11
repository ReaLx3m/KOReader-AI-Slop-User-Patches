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
  Copy to:  koreader/patches/2-smart-multiview.lua

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

if FileChooser._smart_multiview_patched then return end
FileChooser._smart_multiview_patched = true

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
    -- smart grid
    smart_grid_enabled                    = false,
    dirs_sg_portrait_mosaic_min_cols      = 3,
    dirs_sg_portrait_mosaic_min_rows      = 3,
    dirs_sg_portrait_mosaic_max_cols      = 4,
    dirs_sg_portrait_mosaic_max_rows      = 4,
    dirs_sg_portrait_classic_min_items    = 8,
    dirs_sg_portrait_classic_max_items    = 16,
    dirs_sg_landscape_mosaic_min_cols     = 3,
    dirs_sg_landscape_mosaic_min_rows     = 3,
    dirs_sg_landscape_mosaic_max_cols     = 4,
    dirs_sg_landscape_mosaic_max_rows     = 4,
    dirs_sg_landscape_classic_min_items   = 8,
    dirs_sg_landscape_classic_max_items   = 16,
    files_sg_portrait_mosaic_min_cols     = 2,
    files_sg_portrait_mosaic_min_rows     = 2,
    files_sg_portrait_mosaic_max_cols     = 3,
    files_sg_portrait_mosaic_max_rows     = 3,
    files_sg_portrait_classic_min_items   = 8,
    files_sg_portrait_classic_max_items   = 16,
    files_sg_landscape_mosaic_min_cols    = 2,
    files_sg_landscape_mosaic_min_rows    = 2,
    files_sg_landscape_mosaic_max_cols    = 3,
    files_sg_landscape_mosaic_max_rows    = 3,
    files_sg_landscape_classic_min_items  = 8,
    files_sg_landscape_classic_max_items  = 16,
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

-- ── item counting (for smart grid) ───────────────────────────────────────────

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

-- Generate grids between min and max filtered by orientation shape rule, sorted by area then cols.
-- Portrait: c >= r and c <= r+1  (square or one-wider-than-tall: 2x2, 3x2, 3x3, 4x3, 4x4, 5x4…)
-- Landscape: r >= c and r <= c+1 (square or one-taller-than-wide: 2x2, 2x3, 3x3, 3x4, 4x4, 4x5…)
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

-- Returns the key used to store the enabled/disabled state of a grid.
local function gridKey(prefix, orient, c, r)
    return prefix .. "_sg_" .. orient .. "_grid_" .. c .. "x" .. r
end

-- Pick the smallest enabled grid whose area >= n. Falls back to largest.
local function smartGrid(n, prefix, orient, min_cols, min_rows, max_cols, max_rows)
    local grids = enumGrids(min_cols, min_rows, max_cols, max_rows, orient)
    local fallback_c, fallback_r = max_cols, max_rows
    for _, g in ipairs(grids) do
        local key = gridKey(prefix, orient, g.c, g.r)
        local enabled = get(key)
        -- default: included (nil/absent = included, true = excluded)
        if enabled ~= true then
            fallback_c, fallback_r = g.c, g.r
            if g.area >= n then return g.c, g.r end
        end
    end
    return fallback_c, fallback_r
end

-- ── mode application ──────────────────────────────────────────────────────────

local _last_path
local _last_has_dirs

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
    -- Set on both class and instance. The live-preview callback writes to the
    -- instance, which shadows the class. We must overwrite the instance too.
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
        if fc and fc ~= FileChooser then
            fc.items_per_page = items_per_page
        end
    end
end

local function applyModeForPath(fc, path)
    if not get("enabled") then return end
    if not setupUpvalues(fc) then return end
    local has_dirs = pathHasSubdirs(path)
    if path == _last_path and has_dirs == _last_has_dirs then return end
    _last_path, _last_has_dirs = path, has_dirs
    local prefix = has_dirs and "dirs" or "files"
    local mode   = get(prefix .. "_mode")

    if get("smart_grid_enabled") then
        local n
        if has_dirs then
            n = countItems(path, true) + countItems(path, false)
        else
            n = countItems(path, false)
        end
        if mode == "classic" or mode == nil or mode == "" then
            -- classic: clamp items_per_page between min and max
            -- portrait values are used as canonical for classic mode
            local min_i = get(prefix .. "_sg_portrait_classic_min_items")
            local max_i = get(prefix .. "_sg_portrait_classic_max_items")
            local items = math.max(min_i, math.min(max_i, n))
            applyClassic(fc, items)
        else
            -- pick grid independently per orientation
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
    else
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
            -- Track current spinner values in upvalue locals so close_callback
            -- can read them — close_callback receives no arguments on this build.
            local cur_cols = orig_cols
            local cur_rows = orig_rows
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
                -- Fires on each "Apply" tap: live preview without persisting.
                callback = function(lv, rv)
                    cur_cols = lv
                    cur_rows = rv
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
                -- Fires on dismiss: persist and re-apply the correct mode
                -- for the current folder so the right grid is always used.
                -- NOTE: receives no arguments on this KOReader build.
                close_callback = function()
                    if cur_cols ~= orig_cols or cur_rows ~= orig_rows then
                        set(ck, cur_cols)
                        set(rk, cur_rows)
                    end
                    -- Always re-apply regardless of whether values changed,
                    -- because the live-preview callback may have set wrong
                    -- grid values on FileChooser class for the other context.
                    _last_path = nil
                    _last_has_dirs = nil
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
                _last_has_dirs = nil
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
        T(_("%1 portrait grid"),  section_label), prefix, "portrait",  fc))
    table.insert(t, gridEntry(
        T(_("%1 landscape grid"), section_label), prefix, "landscape", fc))
    return t
end

-- Smart Grid menu builders ─────────────────────────────────────────────────

-- Build the include/exclude checklist for grids between min and max.
-- Grids equal to min×min and max×max are always shown as anchors but cannot
-- be unchecked (they are the boundary; the user controls bounds via the
-- min/max spinners). All intermediate grids get a checkmark toggle.
local function sgIncludeExcludeMenu(prefix, orient, fc)
    local min_cols = get(prefix .. "_sg_" .. orient .. "_mosaic_min_cols")
    local min_rows = get(prefix .. "_sg_" .. orient .. "_mosaic_min_rows")
    local max_cols = get(prefix .. "_sg_" .. orient .. "_mosaic_max_cols")
    local max_rows = get(prefix .. "_sg_" .. orient .. "_mosaic_max_rows")

    -- grids sorted by area then cols (same order smartGrid uses)
    local grids = enumGrids(min_cols, min_rows, max_cols, max_rows, orient)

    -- Filter to just the intermediate grids (exclude the pure min and max corners).
    -- We show all grids including corners, but corners are locked enabled.
    local items = {}
    for _, g in ipairs(grids) do
        local is_min = (g.c == min_cols and g.r == min_rows)
        local is_max = (g.c == max_cols and g.r == max_rows)
        local key    = gridKey(prefix, orient, g.c, g.r)
        local label  = g.c .. "×" .. g.r
        if is_min or is_max then
            -- anchor: always enabled, show as locked with ✓
            table.insert(items, {
                text = label .. (is_min and " (min)" or " (max)"),
                checked_func = function() return true end,
                enabled_func = function() return false end,
                callback = function() end,
            })
        else
            table.insert(items, {
                text = label,
                checked_func = function()
                    -- nil/absent = included (checked), true = excluded (unchecked)
                    return get(key) ~= true
                end,
                callback = function(touchmenu_instance)
                    -- toggle: nil → true (exclude), true → nil (include)
                    set(key, get(key) ~= true and true or nil)
                    _last_path = nil
                    _last_has_dirs = nil
                    touchmenu_instance:updateItems()
                    if fc and get("enabled") and get("smart_grid_enabled") then
                        applyModeForPath(fc, fc.path)
                        fc:updateItems(1, true)
                    end
                end,
            })
        end
    end

    if #items == 0 then
        -- min == max, nothing to show
        return {{ text = "(min and max are the same grid)", enabled_func = function() return false end, callback = function() end }}
    end
    return items
end

-- Sub-menu for one context (dirs or files) within one orientation.
local function sgContextOrientMenu(prefix, ctx_label, orient, orient_label, default_min_c, default_min_r, default_max_c, default_max_r, fc)
    local p = prefix .. "_sg_" .. orient .. "_mosaic_"
    return {
        {
            text_func = function()
                return "Mosaic min grid: " .. get(p .. "min_cols") .. "×" .. get(p .. "min_rows")
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
                    left_min = 1, left_max = 8, left_default = default_min_c,
                    left_precision  = "%01d",
                    right_text      = _("Rows"),
                    right_value     = cur_rows,
                    right_min = 1, right_max = 8, right_default = default_min_r,
                    right_precision = "%01d",
                    keep_shown_on_apply = true,
                    callback = function(lv, rv) cur_cols = lv; cur_rows = rv end,
                    close_callback = function()
                        set(p .. "min_cols", cur_cols)
                        set(p .. "min_rows", cur_rows)
                        _last_path = nil; _last_has_dirs = nil
                        if fc and get("enabled") and get("smart_grid_enabled") then
                            applyModeForPath(fc, fc.path); fc:updateItems(1, true)
                        end
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
        },
        {
            text_func = function()
                return "Mosaic max grid: " .. get(p .. "max_cols") .. "×" .. get(p .. "max_rows")
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
                    left_min = 1, left_max = 8, left_default = default_max_c,
                    left_precision  = "%01d",
                    right_text      = _("Rows"),
                    right_value     = cur_rows,
                    right_min = 1, right_max = 8, right_default = default_max_r,
                    right_precision = "%01d",
                    keep_shown_on_apply = true,
                    callback = function(lv, rv) cur_cols = lv; cur_rows = rv end,
                    close_callback = function()
                        set(p .. "max_cols", cur_cols)
                        set(p .. "max_rows", cur_rows)
                        _last_path = nil; _last_has_dirs = nil
                        if fc and get("enabled") and get("smart_grid_enabled") then
                            applyModeForPath(fc, fc.path); fc:updateItems(1, true)
                        end
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
        },
        {
            text_func = function()
                local min_c = get(p .. "min_cols"); local min_r = get(p .. "min_rows")
                local max_c = get(p .. "max_cols"); local max_r = get(p .. "max_rows")
                if min_c == max_c and min_r == max_r then
                    return "Include/Exclude grids (none — min=max)"
                end
                return "Include/Exclude grids"
            end,
            enabled_func = function()
                return not (get(p .. "min_cols") == get(p .. "max_cols")
                    and get(p .. "min_rows") == get(p .. "max_rows"))
            end,
            sub_item_table_func = function()
                return sgIncludeExcludeMenu(prefix, orient, fc)
            end,
        },
        {
            text_func = function()
                return "Classic min items: " .. get(prefix .. "_sg_" .. orient .. "_classic_min_items")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new{
                    title_text    = ctx_label .. " " .. orient_label .. " classic min items",
                    value         = get(prefix .. "_sg_" .. orient .. "_classic_min_items"),
                    value_min = 1, value_max = 40, value_step = 1, default_value = 8,
                    keep_shown_on_apply = true,
                    callback = function(spin)
                        set(prefix .. "_sg_" .. orient .. "_classic_min_items", spin.value)
                        _last_path = nil; _last_has_dirs = nil
                        touchmenu_instance:updateItems()
                        if fc and get("enabled") and get("smart_grid_enabled") then
                            applyModeForPath(fc, fc.path); fc:updateItems(1, true)
                        end
                    end,
                })
            end,
        },
        {
            text_func = function()
                return "Classic max items: " .. get(prefix .. "_sg_" .. orient .. "_classic_max_items")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new{
                    title_text    = ctx_label .. " " .. orient_label .. " classic max items",
                    value         = get(prefix .. "_sg_" .. orient .. "_classic_max_items"),
                    value_min = 1, value_max = 40, value_step = 1, default_value = 16,
                    keep_shown_on_apply = true,
                    callback = function(spin)
                        set(prefix .. "_sg_" .. orient .. "_classic_max_items", spin.value)
                        _last_path = nil; _last_has_dirs = nil
                        touchmenu_instance:updateItems()
                        if fc and get("enabled") and get("smart_grid_enabled") then
                            applyModeForPath(fc, fc.path); fc:updateItems(1, true)
                        end
                    end,
                })
            end,
        },
    }
end

-- One orientation sub-menu (Portrait or Landscape), with Folders and Files sub-menus.
local function sgOrientMenu(orient, orient_label, fc)
    return {
        {
            text = "Folders",
            sub_item_table_func = function()
                return sgContextOrientMenu("dirs",  "Folders", orient, orient_label, 3, 3, 4, 4, fc)
            end,
        },
        {
            text = "Files",
            sub_item_table_func = function()
                return sgContextOrientMenu("files", "Files",   orient, orient_label, 2, 2, 3, 3, fc)
            end,
        },
    }
end

local function smartGridMenu(fc)
    return {
        {
            text = "Smart Grid",
            checked_func = function() return get("smart_grid_enabled") == true end,
            callback = function(touchmenu_instance)
                set("smart_grid_enabled", not get("smart_grid_enabled"))
                _last_path = nil
                _last_has_dirs = nil
                touchmenu_instance:updateItems()
                if fc and get("enabled") then
                    applyModeForPath(fc, fc.path)
                    fc:updateItems(1, true)
                end
            end,
        },
        {
            text = "Portrait",
            sub_item_table_func = function()
                return sgOrientMenu("portrait", "Portrait", fc)
            end,
        },
        {
            text = "Landscape",
            sub_item_table_func = function()
                return sgOrientMenu("landscape", "Landscape", fc)
            end,
        },
    }
end

-- ── patch setUpdateItemTable ──────────────────────────────────────────────────

local orig_setUpdateItemTable = FileManagerMenu.setUpdateItemTable

function FileManagerMenu:setUpdateItemTable()
    local fc = self.ui and self.ui.file_chooser

    -- Log all available FileManagerMenuOrder keys once.
    if not FileManagerMenuOrder._smart_multiview_logged then
        FileManagerMenuOrder._smart_multiview_logged = true
        local keys = {}
        for k, v in pairs(FileManagerMenuOrder) do
            if type(v) == "table" then
                table.insert(keys, k .. "(" .. #v .. ")")
            end
        end
        table.sort(keys)
        logger.info("smart-multiview: FileManagerMenuOrder keys = " .. table.concat(keys, ", "))
    end

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

    -- Append the Multiview sub-entry into AI Slop Settings.
    table.insert(self.menu_items.ai_slop_settings.sub_item_table, {
        text = _("Multiview"),
        sub_item_table_func = function()
            return {
                {
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
                {
                    text = "Smart Grid",
                    sub_item_table_func = function()
                        return smartGridMenu(fc)
                    end,
                },
            }
        end,
    })

    -- Call the original AFTER we've set everything up.
    orig_setUpdateItemTable(self)
end

logger.info("smart-multiview: patch applied")
