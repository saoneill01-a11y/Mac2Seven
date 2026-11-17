import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskbarSettingsView: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var tracker: WindowTracker
    @EnvironmentObject var thumbnails: Thumbnails
    @State private var dockAway = Dock.isKeptAway
    @State private var dockError: String?

    private var settings: Binding<TaskbarSettings> { $prefs.data.taskbar }

    var body: some View {
        Form {
            Section {
                Toggle("Show the taskbar", isOn: settings.enabled)
            } footer: {
                Text("A Windows-style taskbar along the bottom of the screen. The Start button opens this menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Layout") {
                Picker("Alignment", selection: settings.alignment) {
                    ForEach(TaskbarAlignment.allCases) { Text($0.title).tag($0) }
                }
                Picker("Rows", selection: settings.rows) {
                    ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Buttons", selection: settings.buttons) {
                    ForEach(TaskbarButtons.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show on all displays", isOn: settings.allDisplays)
                Picker("Clock calendar", selection: settings.calendarStyle) {
                    ForEach(CalendarStyle.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                Toggle("Hide apps with no open windows", isOn: settings.hideWindowless)
            } footer: {
                Text("Mac apps keep running after you close their last window. With this on, they leave the taskbar until you open a window again (pinned apps stay). An app whose only window is on another desktop is hidden too, because its window can't be seen from here.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show window previews on hover", isOn: settings.showPreviews)
                Toggle("Keep windows clear of the taskbar", isOn: settings.keepWindowsClear)
                LabeledContent("Mac Dock") {
                    if dockAway {
                        HStack {
                            Text("Hidden").foregroundStyle(.secondary)
                            Button("Show the Dock Again") { setDockAway(false) }
                        }
                    } else {
                        Button("Hide the Dock") { setDockAway(true) }
                    }
                }
                if let dockError { Text(dockError).font(.caption).foregroundStyle(.red) }
            } footer: {
                Text("Windows that macOS zooms or fills to the bottom of the screen stop at the taskbar. With the Dock hidden, Mac2Seven sizes the Dock to the taskbar and keeps it underneath, so macOS itself stops windows there with its usual animation; windows you move by hand can still go behind the bar. Hiding the Dock also keeps it from popping up over the taskbar. Switch apps with the taskbar or ⌘Tab instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                PermissionRow(title: "Accessibility", granted: tracker.hasAccessibility,
                              detail: "Lists windows and lets the taskbar minimize, restore and close them.",
                              grant: { tracker.requestAccessibility() },
                              settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                PermissionRow(title: "Screen Recording", granted: thumbnails.hasPermission,
                              detail: "Shows live window previews. Without it, previews show the app icon.",
                              grant: { thumbnails.requestPermission() },
                              settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            } header: {
                Text("Permissions")
            }

            Section {
                ForEach(prefs.data.taskbar.pinned, id: \.self) { path in
                    HStack {
                        Image(nsImage: IconCache.icon(path)).resizable().frame(width: 18, height: 18)
                        Text(FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""))
                        Spacer()
                        Button { move(path, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(prefs.data.taskbar.pinned.first == path)
                        Button { move(path, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(prefs.data.taskbar.pinned.last == path)
                        Button { prefs.data.taskbar.pinned.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add App…") { addApp() }
            } header: {
                Text("Pinned apps")
            } footer: {
                Text("You can also right-click any taskbar button to pin or unpin it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            dockAway = Dock.isKeptAway
            thumbnails.checkPermission()
            tracker.refresh()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            thumbnails.checkPermission()
            tracker.refresh()
            dockAway = Dock.isKeptAway
        }
    }

    private func move(_ path: String, by offset: Int) {
        var pins = prefs.data.taskbar.pinned
        guard let i = pins.firstIndex(of: path), pins.indices.contains(i + offset) else { return }
        let other = pins[i + offset]
        pins.swapAt(i, i + offset)
        prefs.data.taskbar.pinned = pins
        // Keep the taskbar's dragged order in step: swap the two apps there too.
        var order = prefs.data.taskbar.order
        if !order.isEmpty {
            // A pin added after the last drag isn't in the order yet; add it so the swap shows on the taskbar.
            for p in [path, other] where !order.contains(p) { order.append(p) }
            if let a = order.firstIndex(of: path), let b = order.firstIndex(of: other) {
                order.swapAt(a, b)
                prefs.data.taskbar.order = order
            }
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !prefs.data.taskbar.pinned.contains(url.path) {
            prefs.data.taskbar.pinned.append(url.path)
        }
    }

    private func setDockAway(_ away: Bool) {
        if Dock.setHiddenByUser(away) {
            dockError = nil
            dockAway = away
        } else {
            dockError = "Couldn't change the Dock settings."
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let detail: String
    let grant: () -> Void
    let settingsURL: String

    var body: some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                HStack {
                    Button("Allow…", action: grant)
                    Button("Open Settings") {
                        if let url = URL(string: settingsURL) { NSWorkspace.shared.open(url) }
                    }
                }
            }
        } label: {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Keeps the Mac Dock out of the way of the taskbar by turning on auto-hide with a very long delay, so it
/// never pops up at the bottom edge. Showing it again puts back the user's own auto-hide setting.
enum Dock {
    private static let domain = "com.apple.dock" as CFString
    private static let longDelay: Double = 1000
    /// Remembers whether auto-hide was already on before Mac2Seven hid the Dock.
    private static let autohideWasOnKey = "dockAutohideWasOn"
    /// The user chose Hide the Dock (and hasn't chosen Show the Dock Again). The Dock comes back while
    /// Mac2Seven isn't running and is hidden again when it starts.
    private static let wantsHiddenKey = "dockHiddenByMac2Seven"

    /// The Dock is kept out of the way by showing it under the taskbar, sized to the bar, instead of hiding it.
    /// macOS then keeps zoomed, filled and tiled windows above it (and so above the taskbar), with its own
    /// smooth animation. The Dock's own look (size, magnification, position) is saved and put back later.
    private static let reservingKey = "dockReservingForTaskbar"
    private static let savedLookKey = "dockSavedLook"
    private static let lookKeys: [(key: String, type: String)] = [("tilesize", "-float"), ("magnification", "-bool"),
                                                                  ("orientation", "-string")]

    /// The taskbar's height when the Dock should hold that space (Keep windows clear of the taskbar is on),
    /// or nil to hide the Dock instead. Set by the taskbar before the Dock is hidden.
    static var reserveHeight: CGFloat?

    static var wantsHidden: Bool { UserDefaults.standard.bool(forKey: wantsHiddenKey) }
    /// Mac2Seven has put the Dock under the taskbar (the taskbar draws a solid background then).
    static var isReserving: Bool { UserDefaults.standard.bool(forKey: reservingKey) }

    /// The Hide the Dock / Show the Dock Again buttons.
    @discardableResult
    static func setHiddenByUser(_ hidden: Bool) -> Bool {
        UserDefaults.standard.set(hidden, forKey: wantsHiddenKey)
        return setKeptAway(hidden)
    }

    /// When Mac2Seven quits: show the Dock all the time (no auto-hide), so the Mac is never left without
    /// either. The choice is kept, and the Dock is hidden again when Mac2Seven starts.
    static func restoreForQuit() {
        guard wantsHidden && isKeptAway else { return }
        restoreLook()
        run("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide-delay"])
        run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "false"])
        run("/usr/bin/killall", ["Dock"])
    }

    /// When Mac2Seven starts: hide the Dock again if the user had chosen that and the taskbar is on.
    static func rehideAtLaunch(taskbarOn: Bool) {
        // Versions before 1.3.1 hid the Dock without recording the choice; adopt it if Mac2Seven did the hiding.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: wantsHiddenKey) == nil, defaults.object(forKey: autohideWasOnKey) != nil, isKeptAway {
            defaults.set(true, forKey: wantsHiddenKey)
        }
        // Re-hiding doesn't re-record the user's own auto-hide setting: after a quit it reads "off", which is
        // Mac2Seven's doing, not theirs.
        if wantsHidden && taskbarOn && !isKeptAway { setKeptAway(true, recordOriginal: false) }
    }

    private static func value(_ key: String) -> Any? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key as CFString, domain)
    }

    static var isKeptAway: Bool {
        let hidden = ((value("autohide-delay") as? NSNumber)?.doubleValue ?? 0) >= 100 && (value("autohide") as? Bool ?? false)
        return hidden || (isReserving && !(value("autohide") as? Bool ?? false))
    }

    /// The taskbar's height or setting changed: if the Dock is kept away, switch to the right way of doing it.
    static func reserveHeightChanged(to height: CGFloat?) {
        guard height != reserveHeight else { return }
        reserveHeight = height
        if wantsHidden && isKeptAway { setKeptAway(true, recordOriginal: false) }
    }

    @discardableResult
    static func setKeptAway(_ away: Bool, recordOriginal: Bool = true) -> Bool {
        var ok: Bool
        if away {
            if recordOriginal || UserDefaults.standard.object(forKey: autohideWasOnKey) == nil {
                UserDefaults.standard.set(value("autohide") as? Bool ?? false, forKey: autohideWasOnKey)
            }
            if let height = reserveHeight {
                ok = reserve(height)
            } else {
                restoreLook()
                ok = run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"])
                ok = ok && run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-delay", "-float", String(longDelay)])
            }
        } else {
            restoreLook()
            // Deleting a key that isn't there fails harmlessly, so its result isn't checked.
            run("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide-delay"])
            let wasOn = UserDefaults.standard.bool(forKey: autohideWasOnKey)
            ok = run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", wasOn ? "true" : "false"])
        }
        // The Dock reads its settings when it starts; it restarts on its own right away.
        run("/usr/bin/killall", ["Dock"])
        if away, let height = reserveHeight { calibrate(height, attempt: 0) }
        return ok
    }

    // MARK: Dock under the taskbar

    private static func tileSizeKey(_ height: CGFloat) -> String { "dockTileSizeFor\(Int(height.rounded()))" }

    private static func reserve(_ height: CGFloat) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.dictionary(forKey: savedLookKey) == nil {
            var look: [String: Any] = [:]
            for item in lookKeys { if let v = value(item.key) { look[item.key] = v } }
            defaults.set(look, forKey: savedLookKey)
        }
        defaults.set(true, forKey: reservingKey)
        let saved = defaults.double(forKey: tileSizeKey(height))
        let tile = saved > 0 ? saved : min(max(height - 14, 16), 128)
        run("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide-delay"])
        var ok = run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "false"])
        ok = ok && run("/usr/bin/defaults", ["write", "com.apple.dock", "magnification", "-bool", "false"])
        ok = ok && run("/usr/bin/defaults", ["write", "com.apple.dock", "orientation", "-string", "bottom"])
        ok = ok && run("/usr/bin/defaults", ["write", "com.apple.dock", "tilesize", "-float", String(tile)])
        return ok
    }

    /// Puts back the Dock's own size, magnification and position after it was under the taskbar.
    private static func restoreLook() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: reservingKey)
        guard let look = defaults.dictionary(forKey: savedLookKey) else { return }
        for item in lookKeys {
            if let v = look[item.key] {
                let text: String
                if item.type == "-bool" { text = ((v as? NSNumber)?.boolValue ?? false) ? "true" : "false" } else { text = "\(v)" }
                run("/usr/bin/defaults", ["write", "com.apple.dock", item.key, item.type, text])
            } else {
                run("/usr/bin/defaults", ["delete", "com.apple.dock", item.key])
            }
        }
        defaults.removeObject(forKey: savedLookKey)
    }

    /// The Dock's height isn't exactly its icon size, so measure the space it holds once it has restarted
    /// and adjust the icon size until it matches the taskbar (rounding up, so windows never reach under it).
    /// The result is remembered, so later launches get it right the first time.
    private static func calibrate(_ height: CGFloat, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard isReserving, reserveHeight == height, attempt < 4 else { return }
            let insets = NSScreen.screens.map { $0.visibleFrame.minY - $0.frame.minY }.filter { $0 > 8 }
            guard let inset = insets.first else { return calibrate(height, attempt: attempt + 1) }
            let tile = ((value("tilesize") as? NSNumber)?.doubleValue) ?? Double(height - 14)
            let diff = Double(height - inset)
            if diff <= 0 && diff > -1.5 {
                UserDefaults.standard.set(tile, forKey: tileSizeKey(height))
                return
            }
            let next = min(max((tile + diff).rounded(.up), 16), 128)
            guard next != tile else {
                UserDefaults.standard.set(tile, forKey: tileSizeKey(height))
                return
            }
            run("/usr/bin/defaults", ["write", "com.apple.dock", "tilesize", "-float", String(next)])
            run("/usr/bin/killall", ["Dock"])
            calibrate(height, attempt: attempt + 1)
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
