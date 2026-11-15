# Mac2Seven

A menu bar app launcher with a classic two-column Start-menu layout.

## Use
- **Open:** click the menu bar icon, or press **⌥Space** anywhere.
- **Pinned apps:** right-click any app → *Pin to Start Menu*, or drag an app (from the menu or Finder) onto the list. Drag pinned apps up or down to reorder them; a blue line shows where they'll land.
- **Frequently used:** fills in automatically from the apps you launch.
- **All Programs:** make folders (and subfolders), then drag apps anywhere into a folder (its title or, when open, anywhere in its contents) or use right-click → *Move to Folder*. Drag apps up or down to reorder them, at the top level or inside a folder. Drag a folder onto another folder's title to put it above or below; drop it inside an open folder to make it a subfolder, or on empty space to move it back to the top level. Hovering a closed folder while dragging opens it. Right-click a folder to rename or delete it.
- **Search:** just start typing. Use ↑/↓ to pick a result and Return to open it. Esc clears the search, then closes the menu.
- **Right-click the menu bar icon** for Settings, Show Data Folder, and Quit. New apps appear automatically: the menu rescans your app folders every time it opens.
- **Settings** (right-click → Settings…, or ⌘, while the menu is open):
  - *General:* Launch at Login, the shortcut that opens the menu, and what the power button does.
  - *Appearance:* Light / Dark / Match System, the Glass or Flat theme, and the accent color.
  - *Places:* edit the right-hand column (add folders or apps, separators, rename, reorder), and switch Documents/Pictures/Desktop to your OneDrive folders in one click.
  - *History:* how many frequently used apps to show, and Clear History.

Your pins, folders and history are stored in `~/Library/Application Support/Mac2Seven/library.json`; settings are in `settings.json` in the same folder.

## Build
The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
open Mac2Seven.xcodeproj
```

To sign it, select your team under the target's *Signing & Capabilities* tab (it is ad-hoc signed by default).

Debug launch flags: `--open`, `--open --query text`, `--open --all`, `--settings [general|appearance|places|history]`.
