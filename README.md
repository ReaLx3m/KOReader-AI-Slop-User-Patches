
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

### **Patches tested on Pocketbook Inkpad 3 Pro and KOReader 2025.10 Ghost.**


<img width="384" height="512" alt="Home" src="https://github.com/user-attachments/assets/a8bed22a-0624-4151-a893-13d0af581988" />
<img width="384" height="512" alt="In Folder" src="https://github.com/user-attachments/assets/edd9ad24-01f3-4864-9e23-08c18d78a16f" />

## **Patches Description**

### **2-multiview.lua**

Automatically switches the file browser display mode based on the contents of the folder you're browsing.

Adds a Multiview toggle and a Multiview Settings sub-menu to the filing-cabinet icon menu under Settings.
- 2 modes(Folder Mode and File Mode), both modes are independently configurable via the Multiview Settings menu. You can choose any rows/columns configuration with "Mosaic With Covers" view mode and any number of items with "Classic" mode view.
- Folders that contain sub-folders or mix of sub-folders and files will display in the mode you set in "Folder Mode", Classic mode is set as default.
- Folders that contain only files will display in the mode you set in "File Mode", Mosaic mode with cover images is set as default.



### **2-folder-cover-stack-left-spine-label-top.lua**

- Replaces the default folder icon in mosaic view with a visual book-stack effect.
- Adds a thumbnail pulled from the folders contents(book/image). If no books or images are present in the root of the folder it will pull the thumbnail from a subfolder.
- Adds a label at the top showing the folder name.

https://github.com/sebdelsol/KOReader.patches/blob/main/2-browser-folder-cover.lua was used as base and as id like to think, improved :).


### **2-mosaic-vertical-label-left.lua**

- Overlays a vertical filename label(without file extension) on the left edge of each book cover in mosaic view. The label is rotated 90° so the title reads bottom to top.


### **2-mosaic-top-horizontal-label.lua**

- Overlays a horizontal filename label(without file extension) at the top of each book cover in mosaic view, centred within the tile. 


### **2-no-folder-up.lua**

- Removes the folder-up entry from the file browser in all display modes (classic, mosaic, and list), keeping the file list clean.
- Navigation up remains accessible via Long-press home button till nested folder menu pops up, mapping a tap-zone/gesture to the action, long pressing home button if "2-home-hold-go-up.lua" is also installed.


### **2-home-hold-go-up.lua**

- Changes the long-press behaviour of the home button so that it navigates up one folder instead of opening the default nested folders menu. 



