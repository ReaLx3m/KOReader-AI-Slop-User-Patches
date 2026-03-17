
## **How to Install**

Save the patch(.lua file) by clicking the desired one and selecting "Download raw file". 

Go to your Koreader folder:
- Cervantes: /mnt/private/koreader
- Kindle: koreader/
- Kobo: .adds/koreader/
- PocketBook: applications/koreader/

If "patches" folder doesnt exist create it, and just copy the .lua file to the folder.

To disable open the wrench menu>More Tools>Patch Management>After Setup, and uncheck the patch you want disabled. Restart koreader.
Disabling can also be done in explorer by adding .disabled extension to the file, resulting in ".lua.disabled"

To uninstall just delete the file from the "patches" folder.



<p float="left">
<img width="360" height="480" alt="Home" src="https://github.com/user-attachments/assets/773c4e3c-fb08-465e-958c-dc16777606c7" />
<img width="360" height="480" alt="In Folder" src="https://github.com/user-attachments/assets/edd9ad24-01f3-4864-9e23-08c18d78a16f" />
</p>

## **Patches Description**

### **[2-multiview.lua](https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/2-multiview.lua)**

Automatically switches the file browser display mode based on the contents of the folder you're browsing. Making it possible to have home menu and folders with sub-folders in classic view with many items per page, or in mosaic view with a large grid like 4x4, 5x5 etc. for better view of your library. And still enjoy large covers, ex. 2x2 or 3x3 mosaic view, when you access a folder with files(books).

Added Settings sub-menu(AI Slop Settings) to the filing-cabinet icon menu on the top bar.
- 2 modes(Folder Mode and File Mode), both modes are independently configurable via the Multiview Settings menu. You can choose any rows/columns configuration with "Mosaic With Covers" view mode and any number of items with "Classic" mode view.
- Folders that contain sub-folders or mix of sub-folders and files will display in the mode you set in "Folder Mode", Classic mode is set as default.
- Folders that contain only files will display in the mode you set in "File Mode", Mosaic mode with cover images is set as default.


### **[2-multiview-smart.lua](https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/2-multiview-smart.lua)**

Does everything Multiview does, but adds "Smart Grid" setting. You set your min and max grid sizes and it decides the grid size based on number of sub-folders/files. 

Ex. If for portrait orientation you set min grid 2x2 and max grid 4x4: 1-4 items will display in 2x2, 5-6 will display in 3x2, 7-9 will display in 3x3, 10-12 in 4x3. 13-16(and over 16) in 4x4. You can uncheck unwanted inbetween grids in the grids settings sub-menu.

Will be unifying patches settings location going forward, so this one(and future updates of the rest of the patches) will have their settings in "AI Slop Settings" sub-menu of the browser menu(filing cabinet icon). 

### **[2-real-books.lua](https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/2-real-books.lua)**

Evolution of Vertical label advanced.

<p float="left">
<img width="360" height="480" alt="Real books 1" src="https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/images/Real%20books%201.png" />
<img width="360" height="480" alt="Real books 2" src="https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/images/Real%20books%202.png" />
</p>

Styled to look like a physical book.
The label displays a vertical strip of the cover's own artwork as background. Text is painted at full opacity on top, with an adjustable lean. Both the top and bottom of the label are cut at angles with a subtle convex curve, and a stack of horizontal lines above the cover that suggest page count - their count determined dynamically by the book's page count.

Features:

- Spine art sampled from the book's left vertical edge and stretched to fill the spine
- Configurable opacity, text style (white on black / black on white), font face and size(10-16)
- Dynamic page-edge lines: count scales with page count via configurable thresholds, with per-tier enable/disable toggles
- Page count sourced from metadata, by adding p654(or any other number) at the end of filename to represent the page count, or estimated from file size(user configurable values) as fallback.
- Supports up to 10 line tiers (2–10 lines) simulating pages to represent book thickness, 6 by default. Once you make a change in the line tiers, exit the menu and enter it again so the settings for selected tiers are shown. If you set over 6 lines youll most likely need to reduce line thickness to 1px so the lines dont overlap the cover on top. 
- Settings accessible under Settings> AI Slop Settings> Real Books

For automating adding pagecount argument(p654 etc.) at the end of the file you can use Calibre, follow [JoshuaCant's guide](https://github.com/joshuacant/ProjectTitle/wiki/Configure-Calibre-Page-Counts)

Looks better with [alternative reading status icons](https://github.com/SeriousHornet/KOReader.patches/blob/main/2-new-status-icons.lua), default ones break immersion imo.




### **[2-folder-cover-stack-left-spine-label-top.lua](https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/2-folder-cover-stack-left-spine-label-top.lua)**

- Replaces the default folder icon in mosaic view with a visual book-stack effect.
- Adds a thumbnail pulled from the folders contents(book/image). If no books or images are present in the root of the folder it will pull the thumbnail from a subfolder.
- Adds a label at the top showing the folder name.
- Bottom label with folder/file count and icons to represent each respectively.

https://github.com/sebdelsol/KOReader.patches/blob/main/2-browser-folder-cover.lua was used as base. I added some functionality and made some cosmetic changes.


### **[2-mosaic-vertical-label-left.lua](https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/2-mosaic-vertical-label-left.lua)**

- Overlays a vertical filename label(without file extension) on the left edge of each book cover in mosaic view. The label is rotated 90° so the title reads bottom to top.

### **[2-mosaic-vertical-label-advanced.lua](https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/2-mosaic-vertical-label-advanced.lua)**

If the simplicity of 2-mosaic-vertical-label-left.lua isnt enough for you, then go for this one. Added Settings sub-menu(AI Slop Settings) to the filing-cabinet icon menu on the top bar.
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


### **[2-ftp-folder-download-nlst-size](https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/2-ftp-folder-download-nlst-size.lua)**
Adds a full-featured download manager to the built-in FTP browser.

NLST to retrieve entry names, then SIZE probe on a single TCP connection to determine file vs directory - reliable for dotted folder names (ex. Vol.1)

- ▶ prefix on folders for visual distinction
- Natural sorting - 1, 2, 10 instead of 1, 10, 2 available in settings(on by default).


Long-press any folder or file to open a paginated selection dialog. If folder is long-pressed you get a selection from its contents(1 level deep), if file is long pressed you get a selection from the contents of the parent folder(folder youre currently in)

- Tap items to check/uncheck individually

- All / None - tap to check/uncheck items on current page, long-press to check/uncheck on all pages

- Page indicator is tappable, you can enter any page number directly


Download

- Files streamed directly to disk - no memory buffering
- Recursive subfolder download
- Per-file progress throughout
- Silent skip or overwrite existing files selectable in settings menu

Settings available under Browser Settings> AI Slop Settings> FTP Folder Download

### **[2-ftp-folder-download-mlsd-list](https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/2-ftp-folder-download-mlsd-list.lua)**

Same as 2-ftp-folder-download-nlst-size functionality wise, but faster at expense of bit reduced compatibility with old servers. If FTP servers you use dont work with this one, use 2-ftp-folder-download-nlst-size.

- MLSD as primary listing method - folder detection based on explicit metadata, not filename heuristics
- Dotted folder names (ex. Vol.1) correctly identified as folders
- LIST fallback using a Lua port of [D.J. Bernstein's ftpparse](https://cr.yp.to/ftpparse.html), covering 9 formats: EPLF, UNIX ls, Microsoft FTP Service, Windows NT FTP Server, VMS, WFTPD, NetPresenz, NetWare, MSDOS

### **Patches tested on KOReader 2025.10 Ghost.**

