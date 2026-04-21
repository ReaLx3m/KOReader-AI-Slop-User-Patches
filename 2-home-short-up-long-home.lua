--[[
User patch: Short-press home button → go up one folder.
             Long-press home button  → go to home folder.

This is the inverse of the default behaviour (short = home, long = folder menu).

Installation:
  Copy this file to:  koreader/patches/2-home-short-up-hold-home.lua

  If you also have 2-home-hold-go-up.lua installed, remove it — they conflict.
--]]

local FileManager     = require("apps/filemanager/filemanager")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local logger          = require("logger")

if FileManager._home_swap_patched then return end
FileManager._home_swap_patched = true

-- Short press: go up one folder (original onHome goes to home_dir).
local orig_onHome = FileManager.onHome
function FileManager:onHome()
    local cur = self.file_chooser and self.file_chooser.path
    if cur then
        local parent = cur:match("^(.*)/[^/]+$")
        if parent and parent ~= "" and parent ~= cur then
            self.file_chooser:changeToPath(parent)
            return true
        end
    end
    -- Already at filesystem root — fall back to original (go to home_dir)
    return orig_onHome(self)
end

-- Long press: go to home folder (original onShowFolderMenu shows a menu).
local orig_onShowFolderMenu = FileManager.onShowFolderMenu
function FileManager:onShowFolderMenu()
    local home_dir = G_reader_settings:readSetting("home_dir")
                     or filemanagerutil.getDefaultDir()
    if home_dir and self.file_chooser then
        self.file_chooser:changeToPath(home_dir)
        return true
    end
    -- Fallback: show the original folder menu if home_dir not set
    return orig_onShowFolderMenu(self)
end

logger.info("home-short-up-hold-home: patch applied")
