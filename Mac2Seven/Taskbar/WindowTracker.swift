import AppKit
import ApplicationServices
import Combine
import os

/// Private but long-stable call (used by most window managers) that maps an AX window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// One window of a running app.
struct TaskWindow: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    var title: String
    var minimized: Bool
}

/// One taskbar entry: a pinned app, a running app, or both.
struct TaskApp: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    var pid: pid_t?
    var windows: [TaskWindow]
    var pinned: Bool
    var isFrontmost: Bool
    var isHidden: Bool

    var isRunning: Bool { pid != nil }
}

/// Watches running apps and their windows (through the Accessibility API) and performs window actions.
@MainActor
final class WindowTracker: ObservableObject {
    @Published private(set) var apps: [TaskApp] = []
    /// The focused window of the frontmost app.
    @Published private(set) var activeWindow: CGWindowID?
    @Published private(set) var hasAccessibility = AXIsProcessTrusted()

    /// Paths of pinned apps, in taskbar order.
    var pinnedPaths: [String] = [] { didSet { if pinnedPaths != oldValue { refresh() } } }
    /// The order set by dragging buttons; apps not in it keep their default place after the ones that are.
    var orderPaths: [String] = [] { didSet { if orderPaths != oldValue { refresh() } } }
    /// Called on the polling queue with the focused window so it can be moved clear of the taskbar.
    var adjustFocusedWindow: ((AXUIElement) -> Void)?

    private let queue = DispatchQueue(label: "Mac2Seven.windows", qos: .userInitiated)
    private var timer: Timer?
    private var elements: [CGWindowID: AXUIElement] = [:]
    /// Running apps that aren't pinned, in the order they were first seen (so buttons don't jump around).
    private var runningOrder: [String] = []
    private var observers: [NSObjectProtocol] = []
    private var polling = false
    private let log = Logger(subsystem: "com.csioly.Mac2Seven", category: "taskbar")
    private var lastSummary = ""

    func start() {
        guard timer == nil else { return }
        // One app that stops responding must not stall the taskbar: every Accessibility call from Mac2Seven
        // (window lists, titles, minimize, close) gives up after half a second instead of the default ~6 s.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
    }

    /// Shows the system prompt that sends the user to Privacy & Security → Accessibility.
    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        hasAccessibility = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: Polling

    func refresh() {
        #if DEBUG
        if DemoMode.isOn {
            // Screenshots show a made-up set of Apple apps and windows, never what's really open.
            if apps.isEmpty { (apps, activeWindow) = Self.demoApps() }
            hasAccessibility = true
            return
        }
        #endif
        guard !polling else { return }
        polling = true
        hasAccessibility = AXIsProcessTrusted()
        let trusted = hasAccessibility
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && $0.bundleURL != nil
        }
        let snapshot = running.map { (pid: $0.processIdentifier, path: $0.bundleURL!.path,
                                      name: $0.localizedName ?? $0.bundleURL!.deletingPathExtension().lastPathComponent,
                                      hidden: $0.isHidden, active: $0.isActive) }
        let adjust = adjustFocusedWindow
        let known = apps.flatMap(\.windows)
        let knownElements = elements

        queue.async { [weak self] in
            var windows: [pid_t: [TaskWindow]] = [:]
            var elements: [CGWindowID: AXUIElement] = [:]
            var focused: CGWindowID?
            if trusted {
                let existing = Self.existingWindowIDs()
                for app in snapshot {
                    let axApp = AXUIElementCreateApplication(app.pid)
                    AXUIElementSetMessagingTimeout(axApp, 0.3)
                    var list: [TaskWindow] = []
                    for window in Self.windows(of: axApp) {
                        guard Self.isStandard(window), let id = Self.windowID(window) else { continue }
                        let title = Self.string(window, kAXTitleAttribute) ?? ""
                        let minimized = Self.bool(window, kAXMinimizedAttribute) ?? false
                        list.append(TaskWindow(id: id, pid: app.pid, title: title.isEmpty ? app.name : title, minimized: minimized))
                        elements[id] = window
                    }
                    // Some apps stop listing a window once it's minimized (or on another Space). Keep windows
                    // we've already seen for as long as the window still exists, asking it directly for its state.
                    let found = Set(list.map(\.id))
                    for old in known where old.pid == app.pid && !found.contains(old.id) && existing.contains(old.id) {
                        guard let element = knownElements[old.id],
                              let minimized = Self.bool(element, kAXMinimizedAttribute) else { continue }
                        let title = Self.string(element, kAXTitleAttribute) ?? ""
                        list.append(TaskWindow(id: old.id, pid: app.pid, title: title.isEmpty ? old.title : title,
                                               minimized: minimized))
                        elements[old.id] = element
                    }
                    windows[app.pid] = list
                    if app.active, let window = Self.element(axApp, kAXFocusedWindowAttribute) {
                        focused = Self.windowID(window)
                        if let adjust, !(Self.bool(window, kAXMinimizedAttribute) ?? false) { adjust(window) }
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.polling = false
                let summary = "accessibility=\(trusted) apps=\(snapshot.count) windows=\(elements.count)"
                if summary != self.lastSummary {
                    self.lastSummary = summary
                    self.log.notice("Window scan: \(summary, privacy: .public)")
                }
                self.elements = elements
                self.activeWindow = focused
                self.rebuild(snapshot: snapshot, windows: windows)
            }
        }
    }

    /// When each window was first seen, so its button keeps its place instead of following the stacking order.
    private var windowOrder: [CGWindowID: Int] = [:]
    private var nextOrder = 0

    private func rebuild(snapshot: [(pid: pid_t, path: String, name: String, hidden: Bool, active: Bool)],
                         windows unordered: [pid_t: [TaskWindow]]) {
        var windows: [pid_t: [TaskWindow]] = [:]
        for (pid, list) in unordered {
            for window in list where windowOrder[window.id] == nil {
                windowOrder[window.id] = nextOrder
                nextOrder += 1
            }
            windows[pid] = list.sorted { windowOrder[$0.id, default: 0] < windowOrder[$1.id, default: 0] }
        }
        let alive = Set(unordered.values.flatMap { $0.map(\.id) })
        windowOrder = windowOrder.filter { alive.contains($0.key) }
        let byPath = Dictionary(snapshot.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let pinned = pinnedPaths.filter { FileManager.default.fileExists(atPath: $0) }
        let pinnedSet = Set(pinned)
        let runningPaths = snapshot.map(\.path).filter { !pinnedSet.contains($0) }
        runningOrder = runningOrder.filter { runningPaths.contains($0) } + runningPaths.filter { !runningOrder.contains($0) }

        func entry(_ path: String) -> TaskApp {
            let info = byPath[path]
            let name = info?.name ?? FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            return TaskApp(path: path, name: name, pid: info?.pid,
                           windows: info.flatMap { windows[$0.pid] } ?? [],
                           pinned: pinnedSet.contains(path), isFrontmost: info?.active ?? false, isHidden: info?.hidden ?? false)
        }
        var next = pinned.map(entry) + runningOrder.map(entry)
        if !orderPaths.isEmpty {
            let rank = Dictionary(orderPaths.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            next = next.enumerated()
                .sorted { (rank[$0.element.path] ?? orderPaths.count + $0.offset, $0.offset)
                        < (rank[$1.element.path] ?? orderPaths.count + $1.offset, $1.offset) }
                .map(\.element)
        }
        if next != apps { apps = next }
    }

    #if DEBUG
    private static func demoApps() -> ([TaskApp], CGWindowID?) {
        var nextID: CGWindowID = 1
        func app(_ path: String, _ name: String, pinned: Bool, front: Bool = false, _ titles: [String]) -> TaskApp {
            let windows = titles.map { title -> TaskWindow in
                defer { nextID += 1 }
                return TaskWindow(id: nextID, pid: 0, title: title, minimized: false)
            }
            return TaskApp(path: path, name: name, pid: titles.isEmpty && !front ? (pinned ? nil : 0) : 0,
                           windows: windows, pinned: pinned, isFrontmost: front, isHidden: false)
        }
        let apps = [
            app("/System/Library/CoreServices/Finder.app", "Finder", pinned: true, ["Documents", "Downloads"]),
            app("/Applications/Safari.app", "Safari", pinned: true, front: true, ["Start Page", "Travel ideas", "Weather"]),
            app("/System/Applications/Mail.app", "Mail", pinned: true, ["Inbox"]),
            app("/System/Applications/Calendar.app", "Calendar", pinned: true, []),
            app("/System/Applications/Messages.app", "Messages", pinned: true, []),
            app("/System/Applications/Music.app", "Music", pinned: true, ["Listen Now"]),
            app("/System/Applications/Notes.app", "Notes", pinned: false, ["Shopping list"]),
            app("/System/Applications/Photos.app", "Photos", pinned: false, ["Library"]),
        ]
        return (apps, apps[1].windows.first?.id)
    }
    #endif

    /// Moves one window's button before or after another window of the same app (window titles mode).
    /// Windows keep this order while they're open.
    func moveWindow(_ id: CGWindowID, nextTo target: CGWindowID, before: Bool) {
        guard let index = apps.firstIndex(where: { $0.windows.contains { $0.id == id } }) else { return }
        let app = apps[index]
        var ids = app.windows.map(\.id)
        ids.removeAll { $0 == id }
        guard let at = ids.firstIndex(of: target) else { return }
        ids.insert(id, at: before ? at : at + 1)
        // Reuse the app's existing ranks, handed out in the new order.
        var ranks = app.windows.compactMap { windowOrder[$0.id] }.sorted()
        while ranks.count < ids.count { ranks.append(nextOrder); nextOrder += 1 }
        for (k, wid) in ids.enumerated() { windowOrder[wid] = ranks[k] }
        apps[index].windows = ids.compactMap { wid in app.windows.first { $0.id == wid } }
    }

    // MARK: Actions

    func launch(_ path: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config)
    }

    /// What a click on an app's taskbar button does when it has one window or none.
    func toggle(_ app: TaskApp) {
        guard let pid = app.pid else { return launch(app.path) }
        if let window = app.windows.first, app.windows.count == 1 {
            return toggle(window)
        }
        let running = NSRunningApplication(processIdentifier: pid)
        if app.windows.isEmpty {
            // No windows we can see: hide it if it's in front, otherwise bring it forward
            // (opening it again asks the app for a window, like clicking its Dock icon).
            if app.isFrontmost && !app.isHidden { running?.hide() } else { launch(app.path) }
        }
        refreshSoon()
    }

    func toggle(_ window: TaskWindow) {
        if activeWindow == window.id && !window.minimized && isFrontmost(window.pid) {
            minimize(window)
        } else {
            focus(window)
        }
    }

    func focus(_ window: TaskWindow) {
        guard let element = elements[window.id] else { return }
        let pid = window.pid
        queue.async {
            if Self.bool(element, kAXMinimizedAttribute) == true {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            DispatchQueue.main.async {
                let app = NSRunningApplication(processIdentifier: pid)
                if app?.isHidden == true { app?.unhide() }
                app?.activate()
            }
        }
        refreshSoon()
    }

    func minimize(_ window: TaskWindow) {
        guard let element = elements[window.id] else { return }
        queue.async { AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
        refreshSoon()
    }

    func close(_ window: TaskWindow) {
        guard let element = elements[window.id] else { return }
        queue.async {
            if let button = Self.element(element, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
        }
        refreshSoon()
    }

    func closeAll(_ app: TaskApp) {
        app.windows.forEach(close)
    }

    func quit(_ app: TaskApp) {
        guard let pid = app.pid else { return }
        NSRunningApplication(processIdentifier: pid)?.terminate()
        refreshSoon()
    }

    // MARK: Show desktop

    private var hiddenForDesktop: [pid_t] = []

    /// Hides every app (like Show Desktop); a second click brings them back.
    func toggleDesktop() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let visible = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != ownPID
                && $0.bundleIdentifier != "com.apple.finder"
        }
        if visible.isEmpty && !hiddenForDesktop.isEmpty {
            hiddenForDesktop.compactMap { NSRunningApplication(processIdentifier: $0) }.forEach { $0.unhide() }
            hiddenForDesktop = []
        } else {
            hiddenForDesktop = visible.map(\.processIdentifier)
            visible.forEach { $0.hide() }
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.activate()
        }
        refreshSoon()
    }

    private func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.refresh() }
    }

    // MARK: AX helpers

    nonisolated static func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    /// Every window the window server knows about, including minimized ones and ones on other Spaces.
    nonisolated static func existingWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    nonisolated static func isStandard(_ window: AXUIElement) -> Bool {
        string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole as String
    }

    nonisolated static func windowID(_ window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
    }

    nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    nonisolated static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated static func frame(_ window: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    nonisolated static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var s = size
        if let value = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }
}
