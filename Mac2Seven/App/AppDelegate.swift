import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@main
struct Mac2SevenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let panelSize = NSSize(width: 580, height: 620)

    let catalog = AppCatalog()
    let library = Library()
    let menuState = MenuState()
    let fileSearch = FileSearch()
    let prefs = Preferences()
    let updater = UpdaterModel()

    private var statusItem: NSStatusItem!
    private var panel: StartPanel!
    private var hotKey: HotKey?
    private var keyMonitor: Any?
    private var lastClose = Date.distantPast
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        library.load()
        library.startTracking()
        // Each scan spots newly installed apps (New badge) and files them into their developer's folder.
        catalog.onScan = { [weak self] apps in self?.library.noteScan(apps) }
        catalog.refresh()

        menuState.closeHandler = { [weak self] in self?.closePanel() }
        menuState.openSettingsHandler = { [weak self] tab in self?.openSettings(tab: tab) }
        menuState.library = library
        let root = StartMenuView()
            .environmentObject(catalog)
            .environmentObject(library)
            .environmentObject(menuState)
            .environmentObject(fileSearch)
            .environmentObject(prefs)
        panel = StartPanel(size: Self.panelSize, content: root)
        panel.onDismiss = { [weak self] in self?.closePanel() }

        setUpStatusItem()
        // Follow the shortcut setting; switch it off while a new one is being recorded.
        prefs.$data.map(\.hotkey).removeDuplicates()
            .combineLatest(prefs.$isRecordingHotkey.removeDuplicates())
            .sink { [weak self] spec, recording in
                self?.registerHotKey(recording ? nil : spec)
            }
            .store(in: &cancellables)
        installKeyMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showRecoveryNoticeIfNeeded() }

        #if DEBUG
        // Debug only: --settings [tab]
        if let i = CommandLine.arguments.firstIndex(of: "--settings") {
            let args = CommandLine.arguments
            let tab = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : "general"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.openSettings(tab: tab) }
        }
        if CommandLine.arguments.contains("--open") {
            // Debug helpers: --open [--query text | --all]
            let args = CommandLine.arguments
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.openPanel()
                if let i = args.firstIndex(of: "--query"), i + 1 < args.count {
                    self.menuState.query = args[i + 1]
                } else if args.contains("--all") {
                    self.menuState.showingAll = true
                }
            }
        }
        #endif
    }

    /// If a data file couldn't be read, it was renamed rather than overwritten; say so once.
    private func showRecoveryNoticeIfNeeded() {
        let files = [library.recoveredFile, prefs.recoveredFile].compactMap { $0 }
        guard !files.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Mac2Seven couldn't read part of its saved data"
        alert.informativeText = """
            To keep it safe, the unreadable file was renamed instead of being overwritten, and Mac2Seven \
            started with defaults:

            \(files.map(\.lastPathComponent).joined(separator: "\n"))

            You can restore a layout you exported with Settings → Backup → Import.
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show File")
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }

    // MARK: Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "circle.grid.2x2.fill", accessibilityDescription: "Mac2Seven")
        image?.isTemplate = true
        button.image = image
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showStatusMenu()
        } else {
            toggle(fromStatusItem: true)
        }
    }

    private func showStatusMenu() {
        closePanel()
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Start Menu  (\(prefs.data.hotkey.display))", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let reveal = NSMenuItem(title: "Show Data Folder", action: #selector(revealLibrary), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        let about = NSMenuItem(title: "About Mac2Seven", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Mac2Seven", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openFromMenu() { openPanel() }

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc private func showAbout() {
        let link = "https://github.com/saoneill01-a11y/Mac2Seven"
        let credits = NSMutableAttributedString(
            string: "A classic two-column start menu for your Mac.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: "github.com/saoneill01-a11y/Mac2Seven",
                                          attributes: [.font: NSFont.systemFont(ofSize: 11), .link: link]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func revealLibrary() {
        // The folder holding library.json (pins, folders, history) and settings.json.
        NSWorkspace.shared.activateFileViewerSelecting([library.fileURL, prefs.fileURL])
    }

    // MARK: Settings window

    @objc func openSettingsFromMenu() {
        openSettings(tab: nil)
    }

    func openSettings(tab: String?) {
        closePanel()
        if let tab { prefs.settingsTab = tab }
        if settingsWindow == nil {
            let view = SettingsView()
                .environmentObject(prefs)
                .environmentObject(library)
                .environmentObject(catalog)
                .environmentObject(updater)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Mac2Seven Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
        // Nothing needs keyboard focus on open; otherwise the tab bar shows a stray focus ring.
        DispatchQueue.main.async { [weak self] in self?.settingsWindow?.makeFirstResponder(nil) }
    }

    // MARK: Hotkey

    private func registerHotKey(_ spec: HotkeySpec?) {
        hotKey = nil
        guard let spec else { return }
        hotKey = HotKey(keyCode: spec.keyCode, modifiers: spec.modifiers) { [weak self] in
            self?.toggle(fromStatusItem: false)
        }
    }

    // MARK: Panel

    func toggle(fromStatusItem: Bool) {
        if panel.isVisible {
            closePanel()
            return
        }
        // A click on the status item first dismisses the panel (it loses focus); don't reopen it straight away.
        if fromStatusItem, Date().timeIntervalSince(lastClose) < 0.3 { return }
        openPanel()
    }

    func openPanel() {
        catalog.refresh()
        menuState.reset()
        panel.setFrameOrigin(panelOrigin())
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
    }

    func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastClose = Date()
    }

    /// Opens under the menu bar icon on the screen the mouse is on. On other displays it sits the same
    /// distance from the right edge as the icon does on its own screen.
    private func panelOrigin() -> NSPoint {
        let size = Self.panelSize
        let mouse = NSEvent.mouseLocation
        let target = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = target.visibleFrame

        if let button = statusItem.button, let window = button.window, let iconScreen = window.screen {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let x: CGFloat
            let y: CGFloat
            if iconScreen == target {
                x = rect.minX
                y = rect.minY - size.height - 6
            } else {
                x = visible.maxX - (iconScreen.frame.maxX - rect.minX)
                y = visible.maxY - size.height - 6
            }
            return NSPoint(x: min(max(x, visible.minX + 8), visible.maxX - size.width - 8), y: y)
        }
        return NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 6)
    }

    /// Escape and arrow keys work no matter which control has focus.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            let state = self.menuState
            switch Int(event.keyCode) {
            case kVK_Escape:
                if !state.query.isEmpty {
                    state.query = ""
                } else if state.showingAll {
                    state.showingAll = false
                } else {
                    self.closePanel()
                }
                return nil
            case kVK_DownArrow where !state.query.isEmpty:
                state.selection = min(state.selection + 1, max(state.hitCount - 1, 0))
                return nil
            case kVK_UpArrow where !state.query.isEmpty:
                state.selection = max(state.selection - 1, 0)
                return nil
            case kVK_ANSI_Comma where event.modifierFlags.contains(.command):
                self.openSettings(tab: nil)
                return nil
            default:
                return event
            }
        }
    }
}
