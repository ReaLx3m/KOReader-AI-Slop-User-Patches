🛠️ KOReader User Patches

A collection of functional enhancements to customize the KOReader file browser and navigation experience.
📂 Patches Description
🔄 2-multiview.lua

    Smart View Switching: Automatically changes the display mode based on folder contents.

    Logic:

        Folder Mode: Applied to folders containing sub-folders. (Default: Classic)

        File Mode: Applied to folders containing only files. (Default: Mosaic with covers)

    Menu Integration: Adds a Multiview toggle and Settings sub-menu under the filing-cabinet icon (Settings menu).

📚 2-folder-cover-stack-left-spine-label-top.lua

Replaces the default folder icon in mosaic view with a dynamic book-stack effect.

    Thumbnail: Pulls a cover from the folder's contents. If the root is empty, it automatically searches subfolders.

    Label: Displays the folder name clearly at the top of the "spine."

📏 2-mosaic-vertical-label-left.lua

Overlays a sleek, vertical filename label (rotated 90°) on the left edge of book covers.

    Detail: Labels read bottom-to-top; folder tiles remain unlabelled for a clean look.

    Configurable Constants:

        LABEL_ALPHA: Opacity (Default: 0.80)

        LABEL_FONT_SIZE: Font size in points (Default: 16)

        LABEL_PADDING: Padding around text (Default: 4)

🔝 2-mosaic-top-horizontal-label.lua

Adds a semi-transparent horizontal label at the top-center of each book cover.

    Configurable Constants:

        LABEL_ALPHA: Opacity (Default: 0.75)

        LABEL_FONT_SIZE: Font size in points (Default: 14)

        LABEL_PADDING: Padding around text (Default: 4)

🧹 2-no-folder-up.lua & 🏠 2-home-hold-go-up.lua

These patches work together to declutter your file browser:

    No-Folder-Up: Removes the ../ entry from all views for a cleaner list.

    Home-Hold: Re-maps the Long-press Home action to navigate "Up" one level, replacing the default nested folders menu.

📥 How to Install

    Download: Right-click the desired .lua file and select "Save link as..."

    Locate KOReader: Connect your device and find the directory:

        Kindle: koreader/

        Kobo: .adds/koreader/

        PocketBook: applications/koreader/

        Cervantes: /mnt/private/koreader

    Deploy: Look for a folder named patches. If it doesn't exist, create it. Copy your .lua files inside.

⚙️ Management & Uninstall

    Toggle via UI: Go to Wrench Menu > More Tools > Patch Management > After Setup. Uncheck patches to disable them, then Restart KOReader.

    Manual Disable: In your file explorer, rename the file from name.lua to name.lua.disabled.

    Uninstall: Simply delete the .lua file from the patches folder.

📸 Previews

<p align="center">
<img width="48%" alt="Home View" src="https://github.com/user-attachments/assets/a8bed22a-0624-4151-a893-13d0af581988" />
<img width="48%" alt="In Folder View" src="https://github.com/user-attachments/assets/edd9ad24-01f3-4864-9e23-08c18d78a16f" />
</p>
