--[[
User patch: Remove the "../" folder-up entry in all views
(mosaic, list, and classic).

Installation:
  Copy this file to:  koreader/patches/2-no-folder-up.lua

Navigation up is still available via the hamburger menu → Go up,
or by long-pressing the home button (see 2-home-hold-go-up.lua).
--]]

local FileChooser = require("ui/widget/filechooser")
local logger      = require("logger")

if FileChooser._no_go_up_patched then return end
FileChooser._no_go_up_patched = true

local orig = FileChooser.genItemTableFromPath
function FileChooser:genItemTableFromPath(path, ...)
    local item_table = orig(self, path, ...)
    for i = #item_table, 1, -1 do
        if item_table[i].is_go_up then
            table.remove(item_table, i)
        end
    end
    return item_table
end

logger.info("no-folder-up: patch applied")
