local AlphaContainer = require("ui/widget/container/alphacontainer")
local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local Device = require("device")
local FileChooser = require("ui/widget/filechooser")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local ImageWidget = require("ui/widget/imagewidget")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local userpatch = require("userpatch")
local util = require("util")

local _ = require("gettext")
local Screen = Device.screen

local FolderCover = {
    name = ".cover",
    exts = { ".jpg", ".jpeg", ".png", ".webp", ".gif" },
}

local function findCover(dir_path)
    local path = dir_path .. "/" .. FolderCover.name
    for _, ext in ipairs(FolderCover.exts) do
        local fname = path .. ext
        if util.fileExists(fname) then return fname end
    end
end

local function getMenuItem(menu, ...) -- path
    local function findItem(sub_items, texts)
        local find = {}
        local texts = type(texts) == "table" and texts or { texts }
        -- stylua: ignore
        for _, text in ipairs(texts) do find[text] = true end
        for _, item in ipairs(sub_items) do
            local text = item.text or (item.text_func and item.text_func())
            if text and find[text] then return item end
        end
    end

    local sub_items, item
    for _, texts in ipairs { ... } do -- walk path
        sub_items = (item or menu).sub_item_table
        if not sub_items then return end
        item = findItem(sub_items, texts)
        if not item then return end
    end
    return item
end

local function toKey(...)
    local keys = {}
    for _, key in pairs { ... } do
        if type(key) == "table" then
            table.insert(keys, "table")
            for k, v in pairs(key) do
                table.insert(keys, tostring(k))
                table.insert(keys, tostring(v))
            end
        else
            table.insert(keys, tostring(key))
        end
    end
    return table.concat(keys, "")
end

local orig_FileChooser_getListItem = FileChooser.getListItem
local cached_list = {}

function FileChooser:getListItem(dirpath, f, fullpath, attributes, collate)
    local key = toKey(dirpath, f, fullpath, attributes, collate, self.show_filter.status)
    cached_list[key] = cached_list[key] or orig_FileChooser_getListItem(self, dirpath, f, fullpath, attributes, collate)
    return cached_list[key]
end


local function capitalize(sentence)
    local words = {}
    for word in sentence:gmatch("%S+") do
        table.insert(words, word:sub(1, 1):upper() .. word:sub(2):lower())
    end
    return table.concat(words, " ")
end

local Folder = {
    edge = {
        thick = Screen:scaleBySize(3.75 * 0.75),
        margin = Size.line.medium * 1.5,
        width = 0.97,
    },
    face = {
        border_size = Screen:scaleBySize(3.75 * 0.75),
        label_border_size = Size.border.thin,
        alpha = 0.75,
        nb_items_font_size = 14,
        nb_items_margin = Screen:scaleBySize(5),
        dir_max_font_size = 20,
    },
}

local function patchCoverBrowser(plugin)
    local MosaicMenu = require("mosaicmenu")
    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
    if not MosaicMenuItem then return end -- Protect against remnants of project title
    if MosaicMenuItem._foldercover_patch_applied then return end -- already patched, do not run twice
    MosaicMenuItem._foldercover_patch_applied = true
    local original_update = MosaicMenuItem.update
    -- BookInfoManager is an upvalue of the real update; grab it lazily on first
    -- use so it is guaranteed to be initialised by the time we need it.
    local BookInfoManager
    local function getBookInfoManager()
        if not BookInfoManager then
            BookInfoManager = userpatch.getUpValue(original_update, "BookInfoManager")
        end
        return BookInfoManager
    end

    -- setting
    function BooleanSetting(text, name, default)
        self = { text = text }
        self.get = function()
            local setting = getBookInfoManager():getSetting(name)
            if default then return not setting end -- false is stored as nil, so we need or own logic for boolean default
            return setting
        end
        self.toggle = function() return getBookInfoManager():toggleSetting(name) end
        return self
    end

    local settings = {
        crop_to_fit = BooleanSetting(_("Crop folder custom image"), "folder_crop_custom_image", true),
        show_folder_name = BooleanSetting(_("Show folder name"), "folder_name_show", true),
    }

    -- Returns a cached book cover from entries, or nil if none found.
    local function findBookCover(menu, entries, cover_specs)
        for _, entry in ipairs(entries) do
            if entry.is_file or entry.file then
                local bookinfo = getBookInfoManager():getBookInfo(entry.path, true)
                if
                    bookinfo
                    and bookinfo.cover_bb
                    and bookinfo.has_cover
                    and bookinfo.cover_fetched
                    and not bookinfo.ignore_cover
                    and not getBookInfoManager().isCachedCoverInvalid(bookinfo, cover_specs)
                then
                    return bookinfo
                end
            end
        end
        return nil
    end

    -- Recursively searches path then subfolders (depth-first) for a cached book cover.
    local _scanning = false  -- guard against recursive update() calls during subfolder scan

    local function findBookCoverRecursive(menu, path, cover_specs, depth)
        depth = depth or 0
        if depth > 2 then return nil end -- limit recursion depth
        menu._dummy = true
        _scanning = true
        local ok, entries = pcall(menu.genItemTableFromPath, menu, path)
        _scanning = false
        menu._dummy = false
        if not ok then return nil end
        if not entries then return nil end
        -- Check files in this folder first
        local bookinfo = findBookCover(menu, entries, cover_specs)
        if bookinfo then return bookinfo end
        -- Then recurse into subfolders
        for _, entry in ipairs(entries) do
            if not (entry.is_file or entry.file) and entry.path then
                bookinfo = findBookCoverRecursive(menu, entry.path, cover_specs, depth + 1)
                if bookinfo then return bookinfo end
            end
        end
        return nil
    end

    -- cover item
    function MosaicMenuItem:update(...)
        if _scanning then return end  -- bail out entirely during recursive subfolder scan
        original_update(self, ...)
        if self._foldercover_processed or self.menu.no_refresh_covers or not self.do_cover_image then return end

        if self.entry.is_file or self.entry.file or not self.mandatory then return end -- it's a file
        local dir_path = self.entry and self.entry.path
        if not dir_path then return end

        self._foldercover_processed = true

        local cover_file = findCover(dir_path) --custom
        if cover_file then
            local success, w, h = pcall(function()
                local tmp_img = ImageWidget:new { file = cover_file, scale_factor = 1 }
                tmp_img:_render()
                local orig_w = tmp_img:getOriginalWidth()
                local orig_h = tmp_img:getOriginalHeight()
                tmp_img:free()
                return orig_w, orig_h
            end)
            if success then
                self:_setFolderCover { file = cover_file, w = w, h = h, scale_to_fit = settings.crop_to_fit.get() }
                return
            end
        end

        local bookinfo = findBookCoverRecursive(self.menu, dir_path, self.menu.cover_specs)
        if bookinfo then
            self:_setFolderCover { data = bookinfo.cover_bb, w = bookinfo.cover_w, h = bookinfo.cover_h }
        end
    end

    function MosaicMenuItem:_setFolderCover(img)
        local left_w = 2 * (Folder.edge.thick + Folder.edge.margin)
        local top_h = 2 * (Folder.edge.thick + Folder.edge.margin)
        local target = {
            w = self.width - 2 * Folder.face.border_size - left_w,
            h = self.height - 2 * Folder.face.border_size - top_h,
        }

        local img_options = { file = img.file, image = img.data }
        if img.scale_to_fit then
            img_options.scale_factor = math.max(target.w / img.w, target.h / img.h)
            img_options.width = target.w
            img_options.height = target.h
        else
            img_options.scale_factor = math.min(target.w / img.w, target.h / img.h)
        end

        local image = ImageWidget:new(img_options)
        local size = image:getSize()
        local dimen = { w = size.w + 2 * Folder.face.border_size, h = size.h + 2 * Folder.face.border_size }

        local image_widget = FrameContainer:new {
            padding = 0,
            bordersize = Folder.face.border_size,
            image,
            overlap_align = "center",
        }

        local directory, nbitems = self:_getTextBoxes { w = size.w, h = size.h }
        local size = nbitems:getSize()

        local folder_name_widget
        if settings.show_folder_name.get() then
            folder_name_widget = TopContainer:new {
                dimen = dimen,
                FrameContainer:new {
                    padding = 0,
                    padding_top = Screen:scaleBySize(2.6),
                    padding_left = Screen:scaleBySize(2.6),
                    bordersize = 0,
                    AlphaContainer:new { alpha = Folder.face.alpha, directory },
                },
                overlap_align = "center",
            }
        else
            folder_name_widget = VerticalSpan:new { width = 0 }
        end

        local nbitems_widget
        if nbitems.text and nbitems.text ~= "" then
            local nb_text_size = nbitems:getSize()
            local rect_h = nb_text_size.h + Folder.face.nb_items_margin
            local bottom_margin = math.floor(dimen.h * 0.02)
            nbitems_widget = BottomContainer:new {
                dimen = { w = dimen.w, h = dimen.h - bottom_margin },
                CenterContainer:new {
                    dimen = { w = dimen.w, h = rect_h },
                    FrameContainer:new {
                        padding = 0,
                        padding_left = Screen:scaleBySize(3),
                        padding_right = Screen:scaleBySize(3),
                        padding_top = Screen:scaleBySize(1),
                        padding_bottom = Screen:scaleBySize(1),
                        bordersize = 0,
                        radius = Screen:scaleBySize(3),
                        background = Blitbuffer.COLOR_WHITE,
                        nbitems,
                    },
                },
                overlap_align = "center",
            }
        else
            nbitems_widget = VerticalSpan:new { width = 0 }
        end

        -- Each ghost book peeks out from behind the cover, offset up and to the left.
        -- The cover sits at bottom-right; ghost books are offset up-left from it.
        -- book2 is one step behind (offset left+up), book3 is two steps behind.

        local img_top  = top_h + math.max(0, math.floor((target.h - dimen.h) * 0.5))
        local img_left = left_w

        local step = Folder.edge.thick + Folder.edge.margin

        -- book2 origin (one step up-left from cover)
        local b2_left = img_left - step
        local b2_top  = img_top  - step

        -- book3 origin (two steps up-left from cover)
        local b3_left = img_left - step * 2
        local b3_top  = img_top  - step * 2

        local function bookL(bx, by, w, h, color)
            -- L-shape: top edge + left edge meeting at top-left corner
            return {
                OverlapGroup:new {
                    dimen = { w = w, h = Folder.edge.thick },
                    overlap_offset = { bx, by },
                    LineWidget:new { background = color, dimen = { w = w, h = Folder.edge.thick } },
                },
                OverlapGroup:new {
                    dimen = { w = Folder.edge.thick, h = h },
                    overlap_offset = { bx, by },
                    LineWidget:new { background = color, dimen = { w = Folder.edge.thick, h = h } },
                },
            }
        end

        -- Short horizontal connector at the bottom of a vertical edge,
        -- bridging from one layer's left edge to the next layer's left edge.
        local function bookConnector(bx, by, h, color)
            return OverlapGroup:new {
                dimen = { w = step, h = Folder.edge.thick },
                overlap_offset = { bx, by + h - Folder.edge.thick },
                LineWidget:new { background = color, dimen = { w = step, h = Folder.edge.thick } },
            }
        end

        -- Short vertical connector at the right end of a horizontal top edge,
        -- dropping down to meet the next layer's top horizontal line.
        local function topConnector(bx, by, w, color)
            return OverlapGroup:new {
                dimen = { w = Folder.edge.thick, h = step },
                overlap_offset = { bx + w - Folder.edge.thick, by },
                LineWidget:new { background = color, dimen = { w = Folder.edge.thick, h = step } },
            }
        end

        local b2 = bookL(b2_left, b2_top, dimen.w, dimen.h, Blitbuffer.COLOR_GRAY_1)
        local b3 = bookL(b3_left, b3_top, dimen.w, dimen.h, Blitbuffer.COLOR_GRAY_2)

        -- Connector: b3's left edge bottom → b2's left edge (short horizontal)
        local b3_connector = bookConnector(b3_left, b3_top, dimen.h, Blitbuffer.COLOR_GRAY_2)
        -- Connector: b2's left edge bottom → cover's left edge (short horizontal)
        local b2_connector = bookConnector(b2_left, b2_top, dimen.h, Blitbuffer.COLOR_GRAY_1)
        -- Connector: b3's top edge right end → b2's top edge (short vertical drop)
        local b3_top_connector = topConnector(b3_left, b3_top, dimen.w, Blitbuffer.COLOR_GRAY_2)
        -- Connector: b2's top edge right end → cover's top edge (short vertical drop)
        local b2_top_connector = topConnector(b2_left, b2_top, dimen.w, Blitbuffer.COLOR_GRAY_1)

        local widget = OverlapGroup:new {
            dimen = { w = self.width, h = self.height },
            -- book3 (furthest back)
            b3[1], b3[2], b3_connector, b3_top_connector,
            -- book2 (middle)
            b2[1], b2[2], b2_connector, b2_top_connector,
            -- cover (front)
            OverlapGroup:new {
                dimen = { w = dimen.w, h = dimen.h },
                overlap_offset = { img_left, img_top },
                image_widget,
                folder_name_widget,
                nbitems_widget,
            },
        }
        if self._underline_container[1] then
            local previous_widget = self._underline_container[1]
            previous_widget:free()
        end

        self._underline_container[1] = widget
    end

    function MosaicMenuItem:_getTextBoxes(dimen)
        local nb_files = tonumber(self.mandatory:match("(%d+) \u{F016}")) or 0
        local nb_dirs  = tonumber(self.mandatory:match("(%d+) \u{F114}")) or 0
        local count_text
        if nb_dirs > 0 and nb_files > 0 then
            count_text = nb_dirs .. " \u{F114} " .. nb_files .. " \u{F016}"
        elseif nb_dirs > 0 then
            count_text = nb_dirs .. " \u{F114}"
        else
            count_text = nb_files .. " \u{F016}"
        end
        local nbitems = TextWidget:new {
            text = count_text,
            face = Font:getFace("cfont", Folder.face.nb_items_font_size),
            bold = true,
            padding = 0,
        }

        local text = self.text
        if text:match("/$") then text = text:sub(1, -2) end -- remove "/"
        text = BD.directory(capitalize(text))
        local available_height = dimen.h - 2 * nbitems:getSize().h
        local dir_font_size = Folder.face.dir_max_font_size
        local directory

        while true do
            if directory then directory:free(true) end
            directory = TextBoxWidget:new {
                text = text,
                face = Font:getFace("cfont", dir_font_size),
                width = dimen.w,
                alignment = "center",
                bold = true,
            }
            if directory:getSize().h <= available_height then break end
            dir_font_size = dir_font_size - 1
            if dir_font_size < 10 then -- don't go too low
                directory:free()
                directory.height = available_height
                directory.height_adjust = true
                directory.height_overflow_show_ellipsis = true
                directory:init()
                break
            end
        end

        return directory, nbitems
    end

    -- menu
    local orig_CoverBrowser_addToMainMenu = plugin.addToMainMenu

    function plugin:addToMainMenu(menu_items)
        orig_CoverBrowser_addToMainMenu(self, menu_items)
        if menu_items.filebrowser_settings == nil then return end

        local item = getMenuItem(menu_items.filebrowser_settings, _("Mosaic and detailed list settings"))
        if item then
            item.sub_item_table[#item.sub_item_table].separator = true
            for i, setting in pairs(settings) do
                if
                    not getMenuItem( -- already exists ?
                        menu_items.filebrowser_settings,
                        _("Mosaic and detailed list settings"),
                        setting.text
                    )
                then
                    table.insert(item.sub_item_table, {
                        text = setting.text,
                        checked_func = function() return setting.get() end,
                        callback = function()
                            setting.toggle()
                            self.ui.file_chooser:updateItems()
                        end,
                    })
                end
            end
        end
    end
end

userpatch.registerPatchPluginFunc("coverbrowser", patchCoverBrowser)
