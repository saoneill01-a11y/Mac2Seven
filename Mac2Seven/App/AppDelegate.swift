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
    static let defaultPanelSize = NSSize(width: 580, height: 620)
    static let minPanelSize = NSSize(width: 480, height: 460)
    /// The Start menu's size (it can be resized), kept within the screen the mouse is on.
    var panelSize: NSSize { panelSize(fromBottom: false) }

    /// The saved size, made to fit the screen the mouse is on: below the menu bar and above the taskbar
    /// (opened from the menu bar), or between the taskbar and the menu bar (opened from the taskbar).
    func panelSize(fromBottom: Bool) -> NSSize {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let floor = (taskbarTop(on: screen) ?? visible.minY) + 8
        let maxHeight = fromBottom ? visible.maxY - floor - 8 : visible.maxY - 6 - floor
        return NSSize(width: min(max(prefs.data.menuWidth, Self.minPanelSize.width), visible.width - 16),
                      height: min(max(prefs.data.menuHeight, Self.minPanelSize.height), maxHeight))
    }

    /// The top edge of the taskbar on this screen, if one is showing there.
    private func taskbarTop(on screen: NSScreen) -> CGFloat? {
        let t = prefs.data.taskbar
        guard t.enabled, t.allDisplays || screen == NSScreen.screens.first else { return nil }
        return screen.frame.minY + taskbar.barHeight
    }

    let catalog = AppCatalog()
    let library = Library()
    let menuState = MenuState()
    let fileSearch = FileSearch()
    let prefs = Preferences()
    let updater = UpdaterModel()
    private(set) lazy var taskbar = TaskbarController(prefs: prefs)
    private(set) lazy var snip = SnipController(prefs: prefs)
    private var snipHotKey: HotKey?

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
        panel = StartPanel(size: panelSize, content: root)
        menuState.resizeHandler = { [weak self] step in self?.resizeMenu(step) }
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
        setUpTaskbar()
        Dock.rehideAtLaunch(taskbarOn: prefs.data.taskbar.enabled)
        setUpSnip()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showRecoveryNoticeIfNeeded() }

        #if DEBUG
        // Debug only: --hover-report writes the bars' Start buttons and hover state to a file every half second.
        if let i = CommandLine.arguments.firstIndex(of: "--hover-report"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                Task { @MainActor in
                    let starts = self.taskbar.startButtonRects().map { "\(Int($0.midX)),\(Int($0.midY))" }.joined(separator: " ")
                    try? "starts \(starts)\nhover \(self.taskbar.hoverState())\nbuttons \(self.taskbar.buttonCentres())\n"
                        .write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
        // Debug only: --snip [rectangle|window|fullScreen|freeform] [--snip-auto | --snip-sample]
        if let i = CommandLine.arguments.firstIndex(of: "--snip") {
            let args = CommandLine.arguments
            let mode = i + 1 < args.count ? SnipMode(rawValue: args[i + 1]) : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let mode { self.prefs.data.snip.mode = mode }
                self.snip.start()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if args.contains("--snip-auto") { self.snip.debugCapture() }
                    if args.contains("--snip-sample") { self.snip.debugSelectSample() }
                    if let j = args.firstIndex(of: "--snip-report"), j + 1 < args.count {
                        // Debug only: writes the current selection to a file every 0.2 s.
                        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                            Task { @MainActor in
                                let r = self.snip.selection?.rect ?? self.snip.shape?.path.bounds ?? .zero
                                try? "x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height))\n"
                                    .write(toFile: args[j + 1], atomically: true, encoding: .utf8)
                            }
                        }
                    }
                    if let j = args.firstIndex(of: "--snip-move-test"), j + 1 < args.count {
                        self.snip.debugMoveTest(report: args[j + 1])
                    }
                }
            }
        }
        // Debug only: --demo --taskbar stages the taskbar with the Start menu and calendar open.
        if DemoMode.isOn, CommandLine.arguments.contains("--taskbar") {
            showDemoBackdrop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.taskbar.stageDemo()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.panel.makeFirstResponder(nil) }
            }
            return
        }
        // Debug only: --demo [--all] stages the menu for marketing screenshots.
        if DemoMode.isOn {
            showDemoBackdrop()
            let all = CommandLine.arguments.contains("--all")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.openPanel()
                self.menuState.showingAll = all
                // Centered on screen, away from the menu bar.
                if let screen = NSScreen.main {
                    let f = screen.frame
                    self.panel.setFrameOrigin(NSPoint(x: f.midX - self.panelSize.width / 2,
                                                      y: f.midY - self.panelSize.height / 2))
                }
                // No text cursor in the search box.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.panel.makeFirstResponder(nil) }
            }
            return
        }
        // Debug only: --settings [tab]
        if let i = CommandLine.arguments.firstIndex(of: "--settings") {
            let args = CommandLine.arguments
            let tab = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : "general"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.openSettings(tab: tab) }
        }
        // Debug only: --text-while-closed opens All Programs, closes the menu, changes the text size to 140%,
        // then reopens All Programs (as changing the slider in Settings does).
        if CommandLine.arguments.contains("--text-while-closed") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.openPanel(); self.menuState.showingAll = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.closePanel()
                    self.prefs.data.textScale = 1.4
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.openPanel(); self.menuState.showingAll = true
                    }
                }
            }
        }
        // Debug only: --text-cycle changes the Start menu text size live, as dragging its slider does.
        if CommandLine.arguments.contains("--text-cycle") {
            let steps: [Double] = [1.0, 1.05, 1.1, 1.15, 1.2, 1.25, 1.3, 1.35, 1.4, 1.35, 1.3, 1.25, 1.2]
            var i = 0
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
                Task { @MainActor in
                    guard i < steps.count else { timer.invalidate(); return }
                    self.prefs.data.textScale = steps[i]
                    i += 1
                }
            }
        }
        // Debug only: --organize-apple runs Settings → Organize's "Move to Apple" (after the first app scan).
        if CommandLine.arguments.contains("--organize-apple") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let apps = self.library.unfiledAppleApps(from: self.catalog.apps, autoHide: self.prefs.data.autoHideHelpers)
                self.library.moveToAppleFolder(apps)
            }
        }
        if CommandLine.arguments.contains("--calendar") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.taskbar.showCalendarForTesting() }
        }
        if CommandLine.arguments.contains("--open") {
            // Debug helpers: --open [--bottom] [--query text | --all]
            let args = CommandLine.arguments
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.openPanel(fromBottom: args.contains("--bottom"))
                if let i = args.firstIndex(of: "--query"), i + 1 < args.count {
                    self.menuState.query = args[i + 1]
                } else if args.contains("--all") {
                    self.menuState.showingAll = true
                }
            }
        }
        #endif
    }

    #if DEBUG
    private var demoBackdrop: NSWindow?

    private func showDemoBackdrop() {
        guard let screen = NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.contentView = NSHostingView(rootView: DemoBackdrop())
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        demoBackdrop = window
    }
    #endif

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
        let shot = NSMenuItem(title: "Take Screenshot  (\(prefs.data.snip.hotkey.display))", action: #selector(snipFromMenu), keyEquivalent: "")
        shot.target = self
        menu.insertItem(shot, at: 1)
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
                .environmentObject(taskbar.tracker)
                .environmentObject(taskbar.thumbnails)
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

    // MARK: Resizing the menu

    private var resizeStart: (mouse: NSPoint, frame: NSRect)?

    /// Drags the menu's grip: from the taskbar the bottom-left corner stays put (it grows up and right);
    /// from the menu bar the top-left corner stays put (it grows down and right).
    private func resizeMenu(_ step: MenuState.ResizeStep) {
        switch step {
        case .began(let moved):
            // Measure from where the press started, not where the drag was first noticed.
            // (SwiftUI's y grows downward; the screen's grows upward.)
            let now = NSEvent.mouseLocation
            resizeStart = (NSPoint(x: now.x - moved.width, y: now.y + moved.height), panel.frame)
        case .changed:
            guard let start = resizeStart else { return }
            let mouse = NSEvent.mouseLocation
            let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
            let visible = screen.visibleFrame
            let floor = (taskbarTop(on: screen) ?? visible.minY) + 8
            let s = start.frame
            let minSize = Self.minPanelSize
            // Never cap below the current size, so the menu doesn't jump when a drag starts.
            let maxWidth = max(visible.maxX - s.minX - 8, s.width)
            let width = max(min(s.width + mouse.x - start.mouse.x, maxWidth), minSize.width)
            var frame: NSRect
            if menuState.fromBottom {
                let maxHeight = max(visible.maxY - s.minY - 8, s.height)
                let height = max(min(s.height + mouse.y - start.mouse.y, maxHeight), minSize.height)
                frame = NSRect(x: s.minX, y: s.minY, width: width, height: height)
            } else {
                // Growing downward stops above the taskbar.
                let maxHeight = max(s.maxY - floor, s.height)
                let height = max(min(s.height - (mouse.y - start.mouse.y), maxHeight), minSize.height)
                frame = NSRect(x: s.minX, y: s.maxY - height, width: width, height: height)
            }
            panel.setFrame(frame, display: true)
        case .ended:
            resizeMenu(.changed) // follow the pointer to where it was let go
            resizeStart = nil
            prefs.data.menuWidth = panel.frame.width
            prefs.data.menuHeight = panel.frame.height
            panel.invalidateShadow()
        case .reset:
            let old = panel.frame
            let size = Self.defaultPanelSize
            let y = menuState.fromBottom ? old.minY : old.maxY - size.height
            panel.setFrame(NSRect(x: old.minX, y: y, width: size.width, height: size.height), display: true)
            prefs.data.menuWidth = size.width
            prefs.data.menuHeight = size.height
            panel.invalidateShadow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // If Mac2Seven hid the Dock for the taskbar, don't leave the Mac without either.
        Dock.restoreForQuit()
    }

    // MARK: Snip

    private func setUpSnip() {
        snip.onWillStart = { [weak self] in
            self?.closePanel()
            self?.taskbar.hidePreviewNow()
            self?.taskbar.hideCalendar()
        }
        snip.onOpenSettings = { [weak self] in self?.openSettings(tab: "screenshots") }
        snip.bottomInset = { [weak self] in
            guard let self, self.prefs.data.taskbar.enabled else { return 0 }
            return self.taskbar.barHeight
        }
        taskbar.onSnip = { [weak self] in self?.snip.start() }
        menuState.snipHandler = { [weak self] in
            // Let the Start menu close first so it isn't in the way.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.snip.start() }
        }
        // Follow the Snip shortcut setting; off while any shortcut is being recorded.
        prefs.$data.map(\.snip.hotkey).removeDuplicates()
            .combineLatest(prefs.$isRecordingHotkey.removeDuplicates())
            .sink { [weak self] spec, recording in
                self?.snipHotKey = nil
                guard !recording else { return }
                self?.snipHotKey = HotKey(keyCode: spec.keyCode, modifiers: spec.modifiers) { [weak self] in
                    self?.snip.start()
                }
            }
            .store(in: &cancellables)
    }

    @objc private func snipFromMenu() { snip.start() }

    // MARK: Taskbar

    private func setUpTaskbar() {
        taskbar.onStart = { [weak self] rect in self?.toggleFromTaskbar(rect) }
        taskbar.onOpenSettings = { [weak self] in self?.openSettings(tab: "taskbar") }
        taskbar.start()
    }

    /// The Start button: opens the menu just above the taskbar, lined up with the button.
    private func toggleFromTaskbar(_ button: NSRect) {
        if panel.isVisible {
            closePanel()
            return
        }
        let size = panelSize(fromBottom: true)
        let screen = NSScreen.screens.first { $0.frame.intersects(button) } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame
        let visible = screen.visibleFrame
        let x = prefs.data.taskbar.alignment == .left ? button.minX : button.minX - 8
        // Keep it clear of a Dock on the side, too.
        let origin = NSPoint(x: min(max(x, visible.minX + 8), visible.maxX - size.width - 8),
                             y: f.minY + taskbar.barHeight + 8)
        openPanel(at: origin, fromBottom: true)
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

    func openPanel(at origin: NSPoint? = nil, fromBottom: Bool = false) {
        catalog.refresh()
        menuState.reset()
        menuState.fromBottom = fromBottom
        panel.anchoredAtBottom = fromBottom
        taskbar.hidePreviewNow()
        panel.setFrame(NSRect(origin: origin ?? panelOrigin(), size: panelSize(fromBottom: fromBottom)), display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
    }

    func closePanel() {
        guard panel.isVisible else { return }
        rememberMenuSize()
        panel.orderOut(nil)
        lastClose = Date()
    }

    /// Saves the menu's current size, so it reopens the same however the resize ended.
    private func rememberMenuSize() {
        resizeStart = nil
        let size = panel.frame.size
        guard size.width >= Self.minPanelSize.width, size.height >= Self.minPanelSize.height else { return }
        if abs(prefs.data.menuWidth - size.width) > 0.5 { prefs.data.menuWidth = size.width }
        if abs(prefs.data.menuHeight - size.height) > 0.5 { prefs.data.menuHeight = size.height }
    }

    /// Opens under the menu bar icon on the screen the mouse is on. On other displays it sits the same
    /// distance from the right edge as the icon does on its own screen.
    private func panelOrigin() -> NSPoint {
        let size = panelSize
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
