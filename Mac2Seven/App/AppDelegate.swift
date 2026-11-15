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
        catalog.refresh()

        menuState.closeHandler = { [weak self] in self?.closePanel() }
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

        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openSettings() }
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
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let reveal = NSMenuItem(title: "Show Data Folder", action: #selector(revealLibrary), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Mac2Seven", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openFromMenu() { openPanel() }

    @objc private func revealLibrary() {
        // The folder holding library.json (pins, folders, history) and settings.json.
        NSWorkspace.shared.activateFileViewerSelecting([library.fileURL, prefs.fileURL])
    }

    // MARK: Settings window

    @objc func openSettings() {
        closePanel()
        if settingsWindow == nil {
            let view = SettingsView()
                .environmentObject(prefs)
                .environmentObject(library)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Mac2Seven Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
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

    private func panelOrigin() -> NSPoint {
        let size = Self.panelSize
        if let button = statusItem.button, let window = button.window, let screen = window.screen {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let visible = screen.visibleFrame
            let x = min(max(rect.minX, visible.minX + 8), visible.maxX - size.width - 8)
            return NSPoint(x: x, y: rect.minY - size.height - 6)
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
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
                self.openSettings()
                return nil
            default:
                return event
            }
        }
    }
}
