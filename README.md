
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







### **[FTP Download Manager Plugin](https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/tree/main/ftpdownloadmanager.koplugin)**

Due to upcoming Koreader changes to cloud storage which will break the patch, FTP DM is now a standalone plugin, which should increase its survivability in the long run. The patch is no longer updated with fixes/features.

To instal create a "ftpdownloadmanager.koplugin" folder in Koreader/Plugins/ and copy the _meta.lua and main.lua files to Koreader/Plugins/ftpdownloadmanager.koplugin/

Adds a full fledged download management interface for FTP.

#### Features
- Unified listing method - tries MLSD > LIST > NLST+SIZE automatically for maximum server compatibility. Plain NLST, which the ftp browser on KOReader uses by default has problems with dissplaying folders with a dot in the name and properly identify files with a dot in the name before the extension. This solves that and also maintains max listing speed, except in a rare occasion when youre connecting to an old server that supports NLST only. LIST fallback using a Lua port of [D.J. Bernstein's ftpparse](https://cr.yp.to/ftpparse.html), covering 9 formats: EPLF, UNIX ls, Microsoft FTP Service, Windows NT FTP Server, VMS, WFTPD, NetPresenz, NetWare, MSDOS
- Adds TLS(FTPS) support to the ftp client for max server compatibility. By default it first tries FTP, if server explicitly alows only TLS over FTP(FTPS) and FTP fails, then it retries the connection with FTPS. Setting available to prioritize FTPS and fallback to plain FTP if FTPS not supported by the server. Note: FTPS has some overhead compared to FTP, so if you want highest possible speed best to stick with FTP unless you have a legitimate reason for FTPS(Like a FTP server exposed to the internet that besides books/comics hosts other sensitive data).
- Search function added that will index the whole server on first search, and then use that on-device index for future searches. You can manually reindex(checkbox option), or have it do an automatic re-index on your next search after given period has passed(configurable in settings, default 7 days). When Search dialog is opened(results displayed) tap the looking glas icon to get back to the folder view. Note: If youre using a public server, hammering it with requests while indexing its contents can/might get you temporarily or permanently banned. So when creating the server entry you can check the "Public Server" box, and at the end youll be presented with a spinner where you can set the listing rate limiting(per folder). 
<img width="360" height="480" alt="FTP Browser" src="https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/images/Search%20Dialog.png" />
<img width="360" height="480" alt="FTP Browser" src="https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/images/Search%20Results.png" />
  
- Folder prefix for visual distinction and file size display in the FTP browser

<img width="360" height="480" alt="FTP Browser" src="https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/images/Folder%20indication.png" />

- Tap any file in the FTP browser to select it for downloading, to select a folder with its sub-folders long tap(short tapping opens the folder for browsing). If folder is selected for downloading the folder structure within it is kept, if individual files are selected from multiple folders downloads the files to the set folder without keeping the folder structure. Setting available to "always keep folder structure", even with single files selected from a folder. Download folder for each FTP server is set at first run, changing the folder can be done via the "Save to /" button. If you want to change the download folder just for the folowing download, long tap the "Download Button" and select the folder, after the download has finished the folder is reset to the one you have set at first start or via the "Save to /" button.
- Both top and the lower area with the folder name serve as back buttons, long tapping lands you in the home folder of the FTP server. While in the home folder(root), tapping those areas will change the download behavior on existing files, Skip or Overwrite visually represented by [S]/[O]
<img width="360" height="480" alt="FTP Browser" src="https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/images/Top-Bottom%20Title-Back%20Buttons.png" />

- Bulk selection - All/None buttons, tap checkmarks everything on the current page, long tap selects everything in that folder.

- Range selection is done by tapping at the far right of an item(where the sizes are), first item tapped marks the starting point and second tap the end point, selecting everything in between as a result.
<img width="360" height="480" alt="FTP Browser" src="https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/images/Range%20Selection.png" />

- Counter next to download button, showing selected item count and combined file size. If folder is selected it wont display the count of the files and folders within it, but will display the total size of the contents. 
<img width="360" height="480" alt="FTP Selection" src="https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/images/Number%20of%20Items-Size%20Count%20.png" />

- Download progress tracking

<img width="250" height="100" alt="FTP Progress 1" src="https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/images/Download%20Progress.png" />
<img width="250" height="100" alt="FTP Progress 2" src="https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/images/Download%20Progress%202.png" />
  
- Natural sort - sorts 1, 2, 10 instead of 1, 10, 2 (on by default)

- Text display modes - names either truncate with ...  or wrap(shrink) to fit, selectable in settings
<img width="360" height="480" alt="FTP Progress 2" src="https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/images/Shrink%20Long%20Names%20to%20Fit.png" />

- Configurable max items per page (10-25), how many will actually display depends on buttons/rows height.

- Gesture shortcut for the FTP browser available in "General" section
<img width="360" height="480" alt="FTP Progress 2" src="https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/images/Gesture%20Shortcut%20in%20General.png" />

- Settings are available under Settings > AI Slop Settings > FTP Download Manager
<img width="360" height="480" alt="FTP Progress 2" src="https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/images/Settings%201.png" />
<img width="360" height="480" alt="FTP Progress 2" src="https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/images/Settings%202.png" />



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
<p float="left">
<img width="360" height="480" alt="Home" src="https://github.com/user-attachments/assets/773c4e3c-fb08-465e-958c-dc16777606c7" />
</p>
- Replaces the default folder icon in mosaic view with a visual book-stack effect.
- Adds a thumbnail pulled from the folders contents(book/image). If no books or images are present in the root of the folder it will pull the thumbnail from a subfolder.
- Adds a label at the top showing the folder name.
- Bottom label with folder/file count and icons to represent each respectively.

https://github.com/sebdelsol/KOReader.patches/blob/main/2-browser-folder-cover.lua was used as base. I added some functionality and made some cosmetic changes.






### **[2-mosaic-vertical-label-left.lua](https://github.com/ReaLx3m/KOReader-AI-Slop-User-Patches/blob/main/2-mosaic-vertical-label-left.lua)**

<p float="left">
<img width="360" height="480" alt="In Folder" src="https://github.com/user-attachments/assets/edd9ad24-01f3-4864-9e23-08c18d78a16f" />
</p>

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


### **Patches tested on KOReader 2026.03 "Snowflake"**

