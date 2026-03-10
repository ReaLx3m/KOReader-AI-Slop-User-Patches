
## **How to Install**

Save the patch(.lua file) by right clicking the desired one and selecting "save link as". 

Go to your Koreader folder:
- Cervantes: /mnt/private/koreader
- Kindle: koreader/
- Kobo: .adds/koreader/
- PocketBook: applications/koreader/

If "patches" folder doesnt exist create it, and just copy the .lua file to the folder.

To disable open the wrench menu>More Tools>Patch Management>After Setup, and uncheck the patch you want disabled. Restart koreader.
Disabling can also be done in explorer by adding .disabled extension to the file, resulting in ".lua.disabled"

To uninstall just delete the file from the "patches" folder.




<img width="384" height="512" alt="Home" src="https://github.com/user-attachments/assets/773c4e3c-fb08-465e-958c-dc16777606c7" />
<img width="384" height="512" alt="In Folder" src="https://github.com/user-attachments/assets/edd9ad24-01f3-4864-9e23-08c18d78a16f" />

## **Patches Description**

### **[2-multiview.lua](https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/2-multiview.lua)**

Automatically switches the file browser display mode based on the contents of the folder you're browsing. Making it possible to have home menu and folders with sub-folders in classic view with many items per page, or in mosaic view with a large grid like 4x4, 5x5 etc. for better view of your library. And still enjoy large covers, ex. 2x2 or 3x3 mosaic view, when you access a folder with files(books) only.

Adds a Multiview toggle and a Multiview Settings sub-menu to the filing-cabinet icon menu on the top bar.
- 2 modes(Folder Mode and File Mode), both modes are independently configurable via the Multiview Settings menu. You can choose any rows/columns configuration with "Mosaic With Covers" view mode and any number of items with "Classic" mode view.
- Folders that contain sub-folders or mix of sub-folders and files will display in the mode you set in "Folder Mode", Classic mode is set as default.
- Folders that contain only files will display in the mode you set in "File Mode", Mosaic mode with cover images is set as default.

When you make changes to the Folder and/or File Modes, it might appear that the changes arent applied. If that happens you need to either press Home or access a different folder from your current one, for the views to refresh and show correctly from there on. Already have a version that fixes that and applies the changes on the fly, but is still not tested. Maybe ill release it maybe not, not a big annoyance as is i think. If you do want that version to try out, ask for it over at "Issues" tab. 


### **[2-folder-cover-stack-left-spine-label-top.lua](https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/2-folder-cover-stack-left-spine-label-top.lua)**

- Replaces the default folder icon in mosaic view with a visual book-stack effect.
- Adds a thumbnail pulled from the folders contents(book/image). If no books or images are present in the root of the folder it will pull the thumbnail from a subfolder.
- Adds a label at the top showing the folder name.
- Bottom label with folder/file count and icons to represent each respectively.

https://github.com/sebdelsol/KOReader.patches/blob/main/2-browser-folder-cover.lua was used as base. I added some functionality and made some cosmetic changes.


### **[2-mosaic-vertical-label-left.lua](https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/2-mosaic-vertical-label-left.lua)**

- Overlays a vertical filename label(without file extension) on the left edge of each book cover in mosaic view. The label is rotated 90° so the title reads bottom to top.

### **[2-mosaic-vertical-label-advanced.lua](https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/2-mosaic-vertical-label-advanced.lua)**

If the simplicity of 2-mosaic-vertical-label-left.lua isnt enough for you, then go for this one. Added Settings sub-menu to the filing-cabinet icon menu on the top bar.
- Position left or right
- Text direction bottom to top or top to bottom
- Label text pulled from filename or metadata. Metadata options are Title, Author-Title and Title-Author.

### **[2-mosaic-top-horizontal-label.lua](https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/2-mosaic-top-horizontal-label.lua)**

- Overlays a horizontal filename label(without file extension) at the top of each book cover in mosaic view, centred within the tile. 


### **[2-no-folder-up.lua](https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/2-no-folder-up.lua)**

- Removes the folder-up entry from the file browser in all display modes (classic, mosaic, and list), keeping the file list clean.
- Navigation up remains accessible via Long-press home button till nested folder menu pops up, mapping a tap-zone/gesture to the action, long pressing home button if "2-home-hold-go-up.lua" is also installed.



### **[2-home-hold-go-up.lua](https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/2-home-hold-go-up.lua)**

- Changes the long-press behaviour of the home button so that it navigates up one folder instead of opening the default nested folders menu. 

### **Patches tested on KOReader 2025.10 Ghost.**

