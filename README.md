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
  - *Organize:* suggests folders by developer (Microsoft, Autodesk…) and creates them in one click; after that, new apps from those developers file themselves. Also controls auto-hiding of helpers and lists hidden apps.
  - *History:* how many frequently used apps to show, and Clear History.
  - *Backup:* export your layout (pins, folders, hidden apps, places, appearance) to a file — e.g. in OneDrive — and import it later or on another Mac. Importing saves your current layout to the data folder first.
- **About Mac2Seven** and **Check for Updates…** are in the menu bar icon's right-click menu.
- **Automatic updates** (via [Sparkle](https://sparkle-project.org)): Mac2Seven checks once a day and asks before installing. Turn it off in Settings → General.
- **More than one display?** The menu opens on the screen your mouse is on.
- **Data safety:** if a saved file ever can't be read, Mac2Seven renames it (`*.unreadable-<date>.json`) instead of overwriting it, and tells you.
- **Hide apps:** right-click → *Hide*. Helpers, installers and uninstallers (names with Helper, Service, Agent, Uninstaller…, or starting with Remove) are hidden automatically unless you've pinned or filed them. Hidden apps live in a *Hidden* folder at the bottom of All Programs and still show up in search.
- **New apps** get a *New* badge for a week (or until you open them), and All Programs shows the badge when something new is waiting.

Your pins, folders and history are stored in `~/Library/Application Support/Mac2Seven/library.json`; settings are in `settings.json` in the same folder.

## Build
The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
open Mac2Seven.xcodeproj
```

To sign it, select your team under the target's *Signing & Capabilities* tab (it is ad-hoc signed by default).

The app icon is drawn by `Tools/make-icon.swift`; run `swift Tools/make-icon.swift` from the repo root to regenerate it.

Debug-build launch flags (not in Release builds): `--open`, `--open --query text`, `--open --all`, `--settings [general|appearance|places|organize|history]`.

## Releasing a new version
1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` (the build number must always go up).
2. Write the release notes in `Tools/release-notes/vX.Y.md`.
3. Commit and push.
4. `Tools/release.sh` does a dry run: universal build, Developer ID signing, notarization, stapling, and a signed Sparkle feed in `dist/vX.Y/`.
5. `Tools/release.sh --publish` does the same and creates the GitHub release with `Mac2Seven-X.Y.zip`, `Mac2Seven.zip` and `appcast.xml`. Installed copies find it through `releases/latest/download/appcast.xml`.

This needs, on the releasing Mac: the Developer ID certificate, the `Mac2Seven-notary` notarytool profile, and the Sparkle private key in the keychain under the `Mac2Seven` account. Keep a backup of that key; without it, installed copies can't accept updates.
