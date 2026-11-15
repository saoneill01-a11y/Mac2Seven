import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskbarSettingsView: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var tracker: WindowTracker
    @EnvironmentObject var thumbnails: Thumbnails
    @State private var dockHidden = Dock.isAutoHidden
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
            }

            Section {
                Toggle("Show window previews on hover", isOn: settings.showPreviews)
                Toggle("Keep windows clear of the taskbar", isOn: settings.keepWindowsClear)
                LabeledContent("Mac Dock") {
                    if dockHidden {
                        Text("Hidden automatically").foregroundStyle(.secondary)
                    } else {
                        Button("Hide the Dock") { hideDock() }
                    }
                }
                if let dockError { Text(dockError).font(.caption).foregroundStyle(.red) }
            } footer: {
                Text("Windows that reach behind the taskbar are made shorter. Hiding the Dock keeps it from covering the taskbar; it still appears when you move the pointer to the bottom edge.")
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
            dockHidden = Dock.isAutoHidden
            thumbnails.checkPermission()
            tracker.refresh()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            thumbnails.checkPermission()
            tracker.refresh()
            dockHidden = Dock.isAutoHidden
        }
    }

    private func move(_ path: String, by offset: Int) {
        var pins = prefs.data.taskbar.pinned
        guard let i = pins.firstIndex(of: path), pins.indices.contains(i + offset) else { return }
        pins.swapAt(i, i + offset)
        prefs.data.taskbar.pinned = pins
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

    private func hideDock() {
        if Dock.setAutoHide(true) {
            dockError = nil
            dockHidden = true
        } else {
            dockError = "Couldn't change the Dock. Turn on “Automatically hide and show the Dock” in System Settings → Desktop & Dock."
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

enum Dock {
    static var isAutoHidden: Bool {
        UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
    }

    /// Uses System Events (the same permission Mac2Seven already asks for to shut down or restart).
    static func setAutoHide(_ on: Bool) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to set autohide of dock preferences to \(on)")?
            .executeAndReturnError(&error)
        return error == nil
    }
}
