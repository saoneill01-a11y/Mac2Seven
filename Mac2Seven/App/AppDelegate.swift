import AppKit
import Carbon.HIToolbox
import ServiceManagement
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

    private var statusItem: NSStatusItem!
    private var panel: StartPanel!
    private var hotKey: HotKey?
    private var keyMonitor: Any?
    private var lastClose = Date.distantPast

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
        panel = StartPanel(size: Self.panelSize, content: root)
        panel.onDismiss = { [weak self] in self?.closePanel() }

        setUpStatusItem()
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            self?.toggle(fromStatusItem: false)
        }
        installKeyMonitor()

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
        let open = NSMenuItem(title: "Open Start Menu  (⌥Space)", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let rescan = NSMenuItem(title: "Rescan Applications", action: #selector(rescan), keyEquivalent: "")
        rescan.target = self
        menu.addItem(rescan)
        let reveal = NSMenuItem(title: "Show Settings File", action: #selector(revealLibrary), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Mac2Seven", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openFromMenu() { openPanel() }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Mac2Seven launch-at-login change failed: \(error)")
        }
    }

    @objc private func rescan() { catalog.refresh() }

    @objc private func revealLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([library.fileURL])
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
            default:
                return event
            }
        }
    }
}
