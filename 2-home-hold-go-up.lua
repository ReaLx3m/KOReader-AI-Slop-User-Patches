--[[
User patch: Long-pressing the home button navigates up one folder.
Falls back to the default folder menu at the filesystem root.

Installation:
  Copy this file to:  koreader/patches/2-home-hold-go-up.lua

How it works:
  The home button long-press calls FileManager:onShowFolderMenu().
  We override that to navigate up instead, falling back to the
  original folder menu only at the filesystem root.
--]]

local FileManager = require("apps/filemanager/filemanager")
local logger      = require("logger")

if FileManager._go_up_hold_patched then return end
FileManager._go_up_hold_patched = true

local orig_onShowFolderMenu = FileManager.onShowFolderMenu

function FileManager:onShowFolderMenu()
    local cur = self.file_chooser and self.file_chooser.path
    if cur then
        local parent = cur:match("^(.*)/[^/]+$")
        if parent and parent ~= "" and parent ~= cur then
            self.file_chooser:changeToPath(parent)
            return
        end
    end
    orig_onShowFolderMenu(self)
end

logger.info("home-hold-go-up: patch applied")
