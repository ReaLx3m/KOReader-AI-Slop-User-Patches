--[[
User patch: Remove the "../" folder-up tile in mosaic/grid view.

Installation:
  Copy this file to:  koreader/patches/2-mosaic-no-folder-up.lua

Navigation up is still available via the hamburger menu → Go up, by asigning a gesture, 
or by long-pressing the home button (if 2-home-hold-go-up.lua is installed).
--]]

local FileChooser = require("ui/widget/filechooser")
local logger      = require("logger")

if FileChooser._no_go_up_patched then return end
FileChooser._no_go_up_patched = true

local orig = FileChooser.genItemTableFromPath
function FileChooser:genItemTableFromPath(path, ...)
    local item_table = orig(self, path, ...)
    if self.display_mode_type ~= "mosaic" then
        return item_table
    end
    for i = #item_table, 1, -1 do
        if item_table[i].is_go_up then
            table.remove(item_table, i)
        end
    end
    return item_table
end

logger.info("mosaic-no-folder-up: patch applied")
