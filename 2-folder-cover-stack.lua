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
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local userpatch = require("userpatch")
local util = require("util")
local FileManagerMenu      = require("apps/filemanager/filemanagermenu")
local FileManagerMenuOrder = require("ui/elements/filemanager_menu_order")
local SpinWidget           = require("ui/widget/spinwidget")
local UIManager            = require("ui/uimanager")

local _folder_stack_settings  -- populated by patchCoverBrowser, read by menu hook

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
        thick  = Screen:scaleBySize(3.75 * 0.75),
        margin = Size.line.medium * 1.5,
        width  = 0.97,
    },
    face = {
        border_size       = Screen:scaleBySize(3.75 * 0.75),
        label_border_size = Size.border.thin,
        alpha             = 0.75,
        nb_items_font_size = 14,
        nb_items_margin   = Screen:scaleBySize(5),
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

    -- setting backed by BookInfoManager (per-library DB setting)
    function BooleanSetting(text, name, default)
        self = { text = text }
        self.get = function()
            local setting = getBookInfoManager():getSetting(name)
            if default then return not setting end
            return setting
        end
        self.toggle = function() return getBookInfoManager():toggleSetting(name) end
        return self
    end

    -- setting backed by G_reader_settings (simple patch preference)
    local function PatchSetting(text, key, default)
        local s = { text = text }
        s.get = function()
            local v = G_reader_settings:readSetting("folder_stack_" .. key)
            return (v == nil) and default or v
        end
        s.toggle = function()
            G_reader_settings:saveSetting("folder_stack_" .. key, not s.get())
        end
        return s
    end

    local settings = {
        crop_to_fit      = BooleanSetting(_("Crop folder custom image"), "folder_crop_custom_image", true),
        show_folder_name = BooleanSetting(_("Show folder name"), "folder_name_show", true),
        stack_right      = PatchSetting("Stack on right side", "right", false),
    }
    _folder_stack_settings = settings

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

    -- Given a maximum available area (max_w × max_h) and a desired aspect ratio
    -- (ratio_w : ratio_h), returns the largest w × h that fits inside the area
    -- while exactly matching the requested ratio (letterbox / fit, not crop).
    local function fitAspectInTarget(max_w, max_h, ratio_w, ratio_h)
        local scale = math.min(max_w / ratio_w, max_h / ratio_h)
        return math.floor(ratio_w * scale + 0.5), math.floor(ratio_h * scale + 0.5)
    end

    function MosaicMenuItem:_setFolderCover(img)
        local stack_right = settings.stack_right.get()
        local side_w = 2 * (Folder.edge.thick + Folder.edge.margin)
        local left_w  = stack_right and 0      or side_w
        local right_w = stack_right and side_w or 0
        local top_h   = side_w
        local target = {
            w = self.width  - 2 * Folder.face.border_size - left_w - right_w,
            h = self.height - 2 * Folder.face.border_size - top_h,
        }

        -- Check whether a forced aspect ratio has been requested.
        local forced_ratio = G_reader_settings:readSetting("folder_stack_aspect_ratio")
        if forced_ratio == "none" then forced_ratio = nil end

        -- cover_w / cover_h = the actual pixel size the cover box will occupy.
        -- When a ratio is forced we shrink the box to that ratio (fitting inside
        -- target); the image is then STRETCHED to fill the box exactly.
        -- Without a forced ratio we fall back to the original scaling logic.
        local cover_w, cover_h
        local img_options = { file = img.file, image = img.data }

        if forced_ratio then
            -- Determine the ratio numerator/denominator.
            local rw, rh
            if forced_ratio == "3:4" then
                rw, rh = 3, 4
            elseif forced_ratio == "2:3" then
                rw, rh = 2, 3
            elseif forced_ratio == "9:16" then
                rw, rh = 9, 16
            end
            -- Fit the desired ratio inside the available target area.
            cover_w, cover_h = fitAspectInTarget(target.w, target.h, rw, rh)
            -- True stretch: render the image at natural size, then scale the blitbuffer
            -- to exactly cover_w x cover_h, ignoring source aspect ratio (no bars, no crop).
            local tmp = ImageWidget:new { file = img.file, image = img.data, scale_factor = 1 }
            tmp:_render()
            local stretched_bb = tmp._bb:scale(cover_w, cover_h)
            tmp:free()
            img_options = { image = stretched_bb, scale_factor = 1, width = cover_w, height = cover_h }
        elseif img.scale_to_fit then
            img_options.scale_factor = math.max(target.w / img.w, target.h / img.h)
            img_options.width  = target.w
            img_options.height = target.h
        else
            img_options.scale_factor = math.min(target.w / img.w, target.h / img.h)
        end


        local image = ImageWidget:new(img_options)
        local size = image:getSize()
        local border_size = Folder.face.border_size
        local dimen = { w = size.w + 2 * border_size, h = size.h + 2 * border_size }

        -- ── shared arc rasterizer ──────────────────────────────────────────────
        -- Draws one quarter-circle ring, row by row, and erases the square corner
        -- region beyond the arc so the result is a true curved corner.
        --   cx, cy      = arc centre (screen coords)
        --   r           = outer radius
        --   t           = line thickness
        --   color       = line colour
        --   quad        = "tl" | "tr" | "bl" | "br"
        --   erase_to_x  = x boundary of the square corner to erase (inclusive)
        local stack_r = Screen:scaleBySize(6)

        local function arcCorner(bb, cx, cy, r, t, color, quad, erase_to_x)
            local r_inner = math.max(0, r - t)
            for di = 0, r do
                local o_dx = math.floor(math.sqrt(math.max(0, r * r         - di * di)) + 0.5)
                local i_dx = r_inner > 0
                    and math.floor(math.sqrt(math.max(0, r_inner * r_inner - di * di)) + 0.5)
                    or 0
                local row = (quad == "tl" or quad == "tr") and (cy - di) or (cy + di)
                if quad == "tl" or quad == "bl" then
                    local x0 = cx - o_dx
                    local x1 = cx - i_dx
                    if x1 >= x0 then bb:paintRect(x0, row, x1 - x0 + 1, 1, color) end
                    if erase_to_x and x0 > erase_to_x then
                        bb:paintRect(erase_to_x, row, x0 - erase_to_x, 1, Blitbuffer.COLOR_WHITE)
                    end
                else -- tr, br
                    local x0 = cx + i_dx
                    local x1 = cx + o_dx
                    if x1 >= x0 then bb:paintRect(x0, row, x1 - x0 + 1, 1, color) end
                    if erase_to_x and x1 < erase_to_x then
                        bb:paintRect(x1 + 1, row, erase_to_x - x1, 1, Blitbuffer.COLOR_WHITE)
                    end
                end
            end
        end

        -- ── cover outline widget ───────────────────────────────────────────────
        -- Draws the image then overdaws a rounded border using arcCorner so all
        -- four corners match the ghost-book L curves exactly (same stack_r, same code).
        local CoverWidget = Widget:extend { width = dimen.w, height = dimen.h }
        function CoverWidget:getSize() return { w = self.width, h = self.height } end
        function CoverWidget:free() image:free() end
        function CoverWidget:paintTo(bb, x, y)
            image:paintTo(bb, x + border_size, y + border_size)
            local w, h   = dimen.w, dimen.h
            local t      = border_size
            local r      = stack_r
            local cx_l   = x + r
            local cx_r   = x + w - 1 - r
            local cy_t   = y + r
            local cy_b   = y + h - 1 - r
            -- straight bars
            bb:paintRect(cx_l,          y,              cx_r - cx_l + 1, t, Blitbuffer.COLOR_BLACK) -- top
            bb:paintRect(cx_l,          y + h - t,      cx_r - cx_l + 1, t, Blitbuffer.COLOR_BLACK) -- bottom
            bb:paintRect(x,             cy_t,           t, cy_b - cy_t + 1, Blitbuffer.COLOR_BLACK) -- left
            bb:paintRect(x + w - t,     cy_t,           t, cy_b - cy_t + 1, Blitbuffer.COLOR_BLACK) -- right
            -- four corners using the same arcCorner helper as the ghost books
            arcCorner(bb, cx_l, cy_t, r, t, Blitbuffer.COLOR_BLACK, "tl", x)
            arcCorner(bb, cx_r, cy_t, r, t, Blitbuffer.COLOR_BLACK, "tr", x + w - 1)
            arcCorner(bb, cx_l, cy_b, r, t, Blitbuffer.COLOR_BLACK, "bl", x)
            arcCorner(bb, cx_r, cy_b, r, t, Blitbuffer.COLOR_BLACK, "br", x + w - 1)
        end
        local image_widget = CoverWidget:new { overlap_align = "center" }

        local inner_w = dimen.w - 2 * border_size
        local directory, nbitems = self:_getTextBoxes { w = inner_w, h = size.h }
        local size = nbitems:getSize()

        local folder_name_widget
        if settings.show_folder_name.get() then
            local alpha_pct = G_reader_settings:readSetting("folder_stack_label_alpha")
            -- addblitFrom is inverted: lower = more transparent, higher = more opaque.
            -- Invert so user-facing 100% = opaque, 0% = invisible (same as count pill).
            local alpha = math.max(0.01, 1 - ((alpha_pct ~= nil) and (alpha_pct / 100) or (1 - Folder.face.alpha)))
            local label_blend = math.floor(alpha * 0xFF)
            local dir_size = directory:getSize()
            local pad_v    = Screen:scaleBySize(2)
            -- lbl_w fills the full inner width so the box touches the border on both sides.
            local lbl_w    = inner_w
            local lbl_h    = dir_size.h + 2 * pad_v
            local lbl_r    = Screen:scaleBySize(3)  -- same radius as count pill

            local TitlePill = Widget:extend { width = lbl_w, height = lbl_h }
            function TitlePill:getSize() return { w = self.width, h = self.height } end
            function TitlePill:free()
                if self._scratch then self._scratch:free(); self._scratch = nil end
                directory:free()
            end
            function TitlePill:paintTo(bb, x, y)
                if not self._scratch then
                    self._scratch = Blitbuffer.new(lbl_w, lbl_h, bb:getType())
                end
                -- Seed with cover pixels so the rounded corners are transparent.
                self._scratch:blitFrom(bb, 0, 0, x, y, lbl_w, lbl_h)
                self._scratch:paintRoundedRect(0, 0, lbl_w, lbl_h, Blitbuffer.COLOR_WHITE, lbl_r)
                -- No horizontal padding: text starts at x=0, centred by TextBoxWidget itself.
                directory:paintTo(self._scratch, 0, pad_v)
                bb:addblitFrom(self._scratch, x, y, 0, 0, lbl_w, lbl_h, label_blend)
            end

            -- Offset by border_size so the box is flush against the inside of the outline.
            folder_name_widget = OverlapGroup:new {
                dimen          = { w = dimen.w, h = dimen.h },
                overlap_offset = { border_size, border_size },
                TopContainer:new {
                    dimen = { w = inner_w, h = dimen.h - 2 * border_size },
                    TitlePill:new {},
                },
            }
        else
            folder_name_widget = VerticalSpan:new { width = 0 }
        end

        local nbitems_widget
        local show_count = G_reader_settings:readSetting("folder_stack_show_count")
        show_count = (show_count == nil) and true or show_count
        if show_count and nbitems.text and nbitems.text ~= "" then
            local nb_text_size = nbitems:getSize()
            local pad_h = Screen:scaleBySize(3)
            local pad_v = Screen:scaleBySize(1)
            local pill_w = nb_text_size.w + 2 * pad_h
            local pill_h = nb_text_size.h + 2 * pad_v
            local bottom_margin = math.floor(dimen.h * 0.02)
            local count_alpha_pct = G_reader_settings:readSetting("folder_stack_count_alpha")
            -- AlphaContainer: alpha=0 is opaque, alpha=1 is invisible (additive blending).
            -- Invert so user-facing 100% = opaque, 0% = invisible.
            local count_alpha = math.max(0.01, 1 - ((count_alpha_pct ~= nil) and (count_alpha_pct / 100) or 0.25))
            local pill_r = Screen:scaleBySize(3)
            local RoundedPill = Widget:extend { width = pill_w, height = pill_h }
            function RoundedPill:getSize() return { w = self.width, h = self.height } end
            function RoundedPill:free()
                if self._scratch then self._scratch:free(); self._scratch = nil end
                nbitems:free()
            end
            function RoundedPill:paintTo(bb, x, y)
                if not self._scratch then
                    self._scratch = Blitbuffer.new(pill_w, pill_h, bb:getType())
                end
                -- Copy the cover pixels into the scratch buffer first so the
                -- rounded-rect corners inherit the cover image instead of black.
                self._scratch:blitFrom(bb, 0, 0, x, y, pill_w, pill_h)
                self._scratch:paintRoundedRect(0, 0, pill_w, pill_h, Blitbuffer.COLOR_WHITE, pill_r)
                nbitems:paintTo(self._scratch, pad_h, pad_v)
                bb:addblitFrom(self._scratch, x, y, 0, 0, pill_w, pill_h,
                    math.floor(count_alpha * 0xFF))
            end
            nbitems_widget = BottomContainer:new {
                dimen = { w = dimen.w, h = dimen.h - bottom_margin },
                CenterContainer:new {
                    dimen = { w = dimen.w, h = pill_h },
                    RoundedPill:new {},
                },
                overlap_align = "center",
            }
        else
            nbitems_widget = VerticalSpan:new { width = 0 }
        end

        -- Each ghost book peeks out from behind the cover, offset up and to the
        -- left (left stack) or up and to the right (right stack).

        local stack_right = settings.stack_right.get()
        local step = Folder.edge.thick + Folder.edge.margin
        local side_w = 2 * step
        local left_w  = stack_right and 0      or side_w
        local top_h   = side_w

        local img_top  = top_h + math.max(0, math.floor((target.h - dimen.h) * 0.5))
        local img_left = stack_right
            and math.max(0, math.floor((target.w - dimen.w) * 0.5))
            or  left_w + math.max(0, math.floor((target.w - dimen.w) * 0.5))


        -- Ghost book origins: offset up + left (left stack) or up + right (right stack)
        local b2_left = stack_right and (img_left + step)     or (img_left - step)
        local b2_top  = img_top - step
        local b3_left = stack_right and (img_left + step * 2) or (img_left - step * 2)
        local b3_top  = img_top - step * 2




        -- Each ghost book is drawn as one continuous hook shape:
        --
        --  Left-stack:
        --    ┌──────────────   ← top bar, rounded top-left outer corner (tl)
        --    │                 ← left side bar
        --    └──              ← bottom-right connector step, rounded br inner corner
        --
        --  Right-stack: mirror image (tr outer, bl inner)
        --
        -- The connector (step) width = step  (= edge.thick + edge.margin)
        -- The connector connects this ghost book's bottom to the line below it.

        local function bookHook(bx, by, w, h, color)
            local t  = Folder.edge.thick
            local r  = stack_r
            local Hook = Widget:extend { width = w + step, height = h + step }
            function Hook:getSize() return { w = w, h = h } end
            function Hook:free() end
            function Hook:paintTo(bb, x, y)
                if stack_right then
                    -- outer corner: top-right
                    local cx_out = x + w - 1 - r
                    local cy_out = y + r
                    -- top bar
                    bb:paintRect(x, y, cx_out - x, t, color)
                    arcCorner(bb, cx_out, cy_out, r, t, color, "tr", x + w - 1)
                    -- top connector: drop at the LEFT end of the top bar (opposite end)
                    local cx_tc = x + r
                    local cy_tc = y + r
                    arcCorner(bb, cx_tc, cy_tc, r, t, color, "tl", x)
                    bb:paintRect(x, cy_tc, t, step - r, color)
                    -- right side bar
                    local side_bottom = y + h - 1 - r
                    bb:paintRect(x + w - t, cy_out, t, side_bottom - cy_out, color)
                    -- inner bottom-right corner into horizontal step
                    local cx_in = x + w - 1 - r
                    local cy_in = y + h - 1 - r
                    arcCorner(bb, cx_in, cy_in, r, t, color, "br", x + w - 1)
                    bb:paintRect(x + w - 1 - r - step, y + h - t, step - r, t, color)
                else
                    -- outer corner: top-left
                    local cx_out = x + r
                    local cy_out = y + r
                    -- top bar
                    bb:paintRect(cx_out, y, w - r, t, color)
                    arcCorner(bb, cx_out, cy_out, r, t, color, "tl", x)
                    -- top connector: drop at the RIGHT end of the top bar (opposite end)
                    local cx_tc = x + w - 1 - r
                    local cy_tc = y + r
                    arcCorner(bb, cx_tc, cy_tc, r, t, color, "tr", x + w - 1)
                    bb:paintRect(x + w - t, cy_tc, t, step - r, color)
                    -- left side bar
                    local side_bottom = y + h - 1 - r
                    bb:paintRect(x, cy_out, t, side_bottom - cy_out, color)
                    -- inner bottom-left corner into horizontal step
                    local cx_in = x + r
                    local cy_in = y + h - 1 - r
                    arcCorner(bb, cx_in, cy_in, r, t, color, "bl", x)
                    bb:paintRect(x + r, y + h - t, step - r, t, color)
                end
            end
            return OverlapGroup:new {
                dimen          = { w = w, h = h },
                overlap_offset = { bx, by },
                Hook:new {},
            }
        end

        local b2 = bookHook(b2_left, b2_top, dimen.w, dimen.h, Blitbuffer.COLOR_GRAY_1)
        local b3 = bookHook(b3_left, b3_top, dimen.w, dimen.h, Blitbuffer.COLOR_GRAY_2)

        local widget = OverlapGroup:new {
            dimen = { w = self.width, h = self.height },
            -- book3 (furthest back)
            b3,
            -- book2 (middle)
            b2,
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

end

userpatch.registerPatchPluginFunc("coverbrowser", patchCoverBrowser)

-- ── AI Slop Settings > Folder Cover Stack ─────────────────────────────────────

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

    -- Create shared AI Slop Settings parent if not already defined.
    if not self.menu_items.ai_slop_settings then
        self.menu_items.ai_slop_settings = {
            text = "AI Slop Settings",
            sub_item_table = {},
        }
    end

    -- Append Folder Cover Stack entry.
    table.insert(self.menu_items.ai_slop_settings.sub_item_table, {
        text = _("Folder Cover Stack"),
        sub_item_table_func = function()
            -- Grab BookInfoManager lazily so coverbrowser is loaded by now.
            local bim
            local ok, b = pcall(require, "bookinfomanager")
            if ok then
                bim = b
            else
                local ok2, MosaicMenu = pcall(require, "mosaicmenu")
                if ok2 and MosaicMenu then
                    local MM = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
                    if MM and MM.update then
                        bim = userpatch.getUpValue(MM.update, "BookInfoManager")
                    end
                end
            end

            local function makeToggle(text, name, default)
                return {
                    text = text,
                    checked_func = function()
                        if not bim then return default end
                        local v = bim:getSetting(name)
                        if default then return not v end
                        return v and true or false
                    end,
                    callback = function()
                        if not bim then return end
                        bim:toggleSetting(name)
                        if fc then fc:updateItems() end
                    end,
                }
            end

            return {
                makeToggle(_("Crop folder custom image"), "folder_crop_custom_image", true),
                makeToggle(_("Show folder name"),         "folder_name_show",          true),
                {
                    text = "Stack on right side",
                    checked_func = function()
                        local v = G_reader_settings:readSetting("folder_stack_right")
                        return v == true
                    end,
                    callback = function(touchmenu_instance)
                        local v = G_reader_settings:readSetting("folder_stack_right")
                        G_reader_settings:saveSetting("folder_stack_right", not (v == true))
                        if fc then fc:updateItems() end
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                },
                {
                    text_func = function()
                        local v = G_reader_settings:readSetting("folder_stack_label_alpha")
                        local pct = (v ~= nil) and v or math.floor(Folder.face.alpha * 100)
                        return "Folder name opacity: " .. pct .. "%"
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local cur = G_reader_settings:readSetting("folder_stack_label_alpha")
                                    or math.floor(Folder.face.alpha * 100)
                        UIManager:show(SpinWidget:new{
                            title_text          = "Folder name opacity",
                            value               = cur,
                            value_min           = 0,
                            value_max           = 100,
                            value_step          = 5,
                            default_value       = math.floor(Folder.face.alpha * 100),
                            keep_shown_on_apply = true,
                            callback = function(spin)
                                G_reader_settings:saveSetting("folder_stack_label_alpha", spin.value)
                                if fc then fc:updateItems() end
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        })
                    end,
                },
                {
                    text_func = function()
                        local v = G_reader_settings:readSetting("folder_stack_aspect_ratio")
                        local label = (not v or v == "none") and "Natural" or v
                        return "Cover aspect ratio: " .. label
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local ratios = { "none", "3:4", "2:3", "9:16" }
                        local labels = { "Natural (no stretch)", "3:4", "2:3", "9:16" }
                        local cur = G_reader_settings:readSetting("folder_stack_aspect_ratio") or "none"
                        -- cycle to next option
                        local next_val = "none"
                        for i, r in ipairs(ratios) do
                            if r == cur then
                                next_val = ratios[(i % #ratios) + 1]
                                break
                            end
                        end
                        G_reader_settings:saveSetting("folder_stack_aspect_ratio", next_val)
                        if fc then fc:updateItems() end
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                    sub_item_table = (function()
                        local ratios = { "none", "3:4", "2:3", "9:16" }
                        local labels = { "Natural (no stretch)", "3:4", "2:3", "9:16" }
                        local items = {}
                        for i, r in ipairs(ratios) do
                            local ratio_val = r
                            table.insert(items, {
                                text = labels[i],
                                checked_func = function()
                                    local v = G_reader_settings:readSetting("folder_stack_aspect_ratio") or "none"
                                    return v == ratio_val
                                end,
                                callback = function(touchmenu_instance)
                                    G_reader_settings:saveSetting("folder_stack_aspect_ratio", ratio_val)
                                    if fc then fc:updateItems() end
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            })
                        end
                        return items
                    end)(),
                },
                {
                    text = "Show item count",
                    checked_func = function()
                        local v = G_reader_settings:readSetting("folder_stack_show_count")
                        return v == nil or v == true
                    end,
                    callback = function(touchmenu_instance)
                        local v = G_reader_settings:readSetting("folder_stack_show_count")
                        local cur = (v == nil) and true or v
                        G_reader_settings:saveSetting("folder_stack_show_count", not cur)
                        if fc then fc:updateItems() end
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                },
                {
                    text_func = function()
                        local v = G_reader_settings:readSetting("folder_stack_count_alpha")
                        local pct = (v ~= nil) and v or 75
                        return "Item count opacity: " .. pct .. "%"
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local cur = G_reader_settings:readSetting("folder_stack_count_alpha") or 75
                        UIManager:show(SpinWidget:new{
                            title_text          = "Item count opacity",
                            value               = cur,
                            value_min           = 0,
                            value_max           = 100,
                            value_step          = 5,
                            default_value       = 75,
                            keep_shown_on_apply = true,
                            callback = function(spin)
                                G_reader_settings:saveSetting("folder_stack_count_alpha", spin.value)
                                if fc then fc:updateItems() end
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        })
                    end,
                },
            }
        end,
    })

    orig_setUpdateItemTable(self)
end
