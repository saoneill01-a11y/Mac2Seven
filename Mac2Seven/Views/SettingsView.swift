import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        TabView(selection: $prefs.settingsTab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag("appearance")
            TaskbarSettingsView()
                .tabItem { Label("Taskbar", systemImage: "dock.rectangle") }
                .tag("taskbar")
            SnipSettingsView()
                .tabItem { Label("Screenshots", systemImage: "scissors") }
                .tag("screenshots")
            PlacesSettings()
                .tabItem { Label("Places", systemImage: "folder") }
                .tag("places")
            OrganizeSettings()
                .tabItem { Label("Organize", systemImage: "wand.and.stars") }
                .tag("organize")
            HistorySettings()
                .tabItem { Label("History", systemImage: "clock") }
                .tag("history")
            BackupSettings()
                .tabItem { Label("Backup", systemImage: "externaldrive") }
                .tag("backup")
        }
        .frame(width: 580, height: 600)
    }
}

// MARK: General

struct GeneralSettings: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var updater: UpdaterModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch Mac2Seven at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("Open the menu with") {
                    HotkeyRecorder(spec: $prefs.data.hotkey, isRecording: $prefs.isRecordingHotkey)
                }
            } footer: {
                Text("Click the shortcut, then press the new keys. It needs at least one of ⌘ ⌥ ⌃.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Power button", selection: $prefs.data.powerAction) {
                    ForEach(PowerAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
            } footer: {
                Text("The main button does this; the arrow next to it lists the other options.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                LabeledContent("Version \(Self.version)") {
                    Button("Check Now") { updater.checkForUpdates() }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(updater.lastChecked.map { "Last checked \($0.formatted(date: .abbreviated, time: .shortened))." }
                     ?? "Mac2Seven checks once a day and asks before installing anything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change this: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Click, then press a key combination to set the global shortcut.
struct HotkeyRecorder: View {
    @Binding var spec: HotkeySpec
    @Binding var isRecording: Bool
    /// What Reset goes back to.
    var defaultSpec: HotkeySpec = .default
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? "Press keys…" : spec.display)
                    .frame(minWidth: 110)
            }
            if spec != defaultSpec && !isRecording {
                Button("Reset") { spec = defaultSpec }
                    .buttonStyle(.link)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == UInt16(kVK_Escape) && mods.isEmpty {
                stop()
                return nil
            }
            guard !mods.subtracting(.shift).isEmpty else {
                NSSound.beep()
                return nil
            }
            spec = HotkeySpec(keyCode: UInt32(event.keyCode),
                              modifiers: Self.carbonModifiers(mods),
                              display: Self.symbols(mods) + Self.keyName(event))
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    static func keyName(_ event: NSEvent) -> String {
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = named[Int(event.keyCode)] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

// MARK: Appearance

struct AppearanceSettings: View {
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $prefs.data.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Theme") {
                Picker("Theme", selection: $prefs.data.theme) {
                    ForEach(ThemeStyle.allCases) { style in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(style.title)
                            Text(style.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Section {
                TextSizeRow(title: "Start menu", scale: $prefs.data.textScale)
                TextSizeRow(title: "Taskbar", scale: $prefs.data.taskbarTextScale)
            } header: {
                Text("Text size")
            }

            Section("Accent color") {
                Toggle("Use the macOS accent color", isOn: $prefs.data.useSystemAccent)
                ColorPicker("Custom color", selection: Binding(
                    get: { Color(hex: prefs.data.accentHex) ?? .blue },
                    set: { prefs.data.accentHex = $0.hexString }
                ), supportsOpacity: false)
                .disabled(prefs.data.useSystemAccent)
            }

            Section {
                Text("Open the menu (\(prefs.data.hotkey.display)) to see your changes; they apply right away.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Places

struct PlacesSettings: View {
    @EnvironmentObject var prefs: Preferences
    @State private var selection: UUID?
    @State private var oneDriveRoots: [URL] = OneDrive.roots()
    @State private var chosenRoot: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("These show in the right-hand column of the menu. Drag to reorder; click a name to rename it.")
                .font(.callout).foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach($prefs.data.places) { $place in
                    PlaceEditorRow(place: $place).tag(place.id)
                }
                .onMove { prefs.data.places.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { prefs.data.places.remove(atOffsets: $0) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 230)

            HStack {
                Button("Add Folder…", action: addFolder)
                Button("Add App…", action: addApp)
                Button("Add Separator") { insert([.separator()]) }
                if !prefs.data.places.contains(where: \.isSnip) {
                    Button("Add Snipping Tool") { insert([.snip()]) }
                }
                Spacer()
                Button("Remove", role: .destructive) {
                    prefs.data.places.removeAll { $0.id == selection }
                    selection = nil
                }
                .disabled(selection == nil)
            }

            GroupBox("OneDrive") {
                VStack(alignment: .leading, spacing: 8) {
                    if oneDriveRoots.isEmpty {
                        Text("No OneDrive folders found on this Mac.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Point Documents, Pictures and Desktop at your OneDrive copies, and add a OneDrive entry.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            if oneDriveRoots.count > 1 {
                                Picker("Account", selection: $chosenRoot) {
                                    ForEach(oneDriveRoots, id: \.path) { root in
                                        Text(OneDrive.displayName(root)).tag(root.path)
                                    }
                                }
                                .frame(maxWidth: 260)
                            } else {
                                Text(OneDrive.displayName(oneDriveRoots[0]))
                            }
                            Spacer()
                            if OneDrive.isUsing(prefs.data.places) {
                                Button("Switch Back to Mac Folders") {
                                    prefs.data.places = OneDrive.revert(prefs.data.places)
                                }
                            }
                            Button("Use OneDrive Folders") {
                                let root = oneDriveRoots.first { $0.path == chosenRoot } ?? oneDriveRoots[0]
                                prefs.data.places = OneDrive.apply(root: root, to: prefs.data.places)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Restore Default Places") {
                    prefs.data.places = PrefsData.defaultPlaces()
                    selection = nil
                }
            }
        }
        .padding(20)
        .onAppear {
            oneDriveRoots = OneDrive.roots()
            if chosenRoot.isEmpty { chosenRoot = OneDrive.bestRoot(oneDriveRoots)?.path ?? "" }
        }
    }

    /// Adds new places just after the selected one, or at the end.
    private func insert(_ places: [Place]) {
        if let selection, let i = prefs.data.places.firstIndex(where: { $0.id == selection }) {
            prefs.data.places.insert(contentsOf: places, at: i + 1)
        } else {
            prefs.data.places.append(contentsOf: places)
        }
        selection = places.last?.id
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        insert(panel.urls.map { Place(title: FileManager.default.displayName(atPath: $0.path), path: $0.path) })
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        insert(panel.urls.map { url in
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            return Place(title: name, path: url.path)
        })
    }
}

struct PlaceEditorRow: View {
    @Binding var place: Place

    var body: some View {
        if place.isSeparator {
            HStack {
                Rectangle().fill(.secondary.opacity(0.4)).frame(height: 1)
                Text("Separator").font(.caption).foregroundStyle(.secondary)
                Rectangle().fill(.secondary.opacity(0.4)).frame(height: 1)
            }
            .padding(.vertical, 4)
        } else {
            HStack(spacing: 8) {
                Image(nsImage: IconCache.icon(place.iconPath))
                    .resizable()
                    .frame(width: 18, height: 18)
                TextField("Name", text: $place.title)
                    .textFieldStyle(.plain)
                    .fontWeight(place.bold ? .semibold : .regular)
                    .frame(maxWidth: 170, alignment: .leading)
                Text(place.isSnip ? "Mac2Seven Snip" : place.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(place.isSnip || FileManager.default.fileExists(atPath: place.path) ? Color.secondary : Color.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contextMenu {
                Toggle("Bold", isOn: $place.bold)
                if !place.isSnip {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([place.url])
                    }
                }
            }
        }
    }
}

// MARK: Organize

struct OrganizeSettings: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var library: Library
    @EnvironmentObject var catalog: AppCatalog
    @State private var suggestions: [Library.FolderSuggestion] = []
    @State private var chosen: Set<String> = []
    @State private var appleApps: [AppItem] = []

    private var hidden: [AppItem] {
        catalog.apps.filter { library.isHidden($0, autoHide: prefs.data.autoHideHelpers) }
    }

    var body: some View {
        Form {
            Section {
                if suggestions.isEmpty {
                    Text("Nothing to suggest: every developer with more than one app is already in a folder.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($suggestions) { $s in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { chosen.contains(s.id) },
                                set: { on in if on { chosen.insert(s.id) } else { chosen.remove(s.id) } }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 3) {
                                if let existingName = s.existingName {
                                    Text("Add to “\(existingName)”").fontWeight(.medium)
                                } else {
                                    HStack(spacing: 6) {
                                        Text("New folder:")
                                        TextField("", text: $s.name, prompt: Text("Folder name"))
                                            .labelsHidden()
                                            .textFieldStyle(.roundedBorder)
                                            .multilineTextAlignment(.leading)
                                            .frame(width: 200)
                                    }
                                }
                                Text(s.apps.map(\.name).sorted().joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    HStack {
                        Spacer()
                        Button(chosen.count == 1 ? "Create 1 Folder" : "Create \(chosen.count) Folders") {
                            library.applySuggestions(suggestions.filter { chosen.contains($0.id) })
                            refresh()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(chosen.isEmpty)
                    }
                }
            } header: {
                Text("Folders by developer")
            } footer: {
                Text("Untick anything you don't want. Afterwards, new apps from these developers go straight into their folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if appleApps.isEmpty {
                    Text("Every Apple app is already in a folder.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(appleApps.map(\.name).sorted().joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button(appleApps.count == 1 ? "Move 1 App to “Apple”" : "Move \(appleApps.count) Apps to “Apple”") {
                                library.moveToAppleFolder(appleApps)
                                refresh()
                            }
                        }
                    }
                }
            } header: {
                Text("Apple apps")
            } footer: {
                Text("Moves Apple's own apps (Safari, Mail, Calendar and so on) into an Apple folder in All Programs. Apple apps you've already put in other folders stay where they are. New Apple apps go straight into the Apple folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hide helpers, installers and uninstallers automatically", isOn: $prefs.data.autoHideHelpers)
            } footer: {
                Text("Apps whose names include Helper, Service, Server, Agent, Shim, Updater, Installer or Uninstaller, or start with Remove, go to the Hidden folder at the bottom of All Programs. Apps you've pinned, put in a folder or unhidden are never hidden. Search still finds hidden apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Hidden apps (\(hidden.count))") {
                if hidden.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    ForEach(hidden) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: IconCache.icon(app.path)).resizable().frame(width: 18, height: 18)
                            Text(app.name)
                            Spacer()
                            Text(library.isManuallyHidden(app.path) ? "Hidden by you" : "Auto-hidden")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Unhide") { library.unhide(app.path) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onChange(of: catalog.apps.count) { _, _ in refresh() }
        .onChange(of: prefs.data.autoHideHelpers) { _, _ in refresh() }
    }

    private func refresh() {
        suggestions = library.suggestions(from: catalog.apps, autoHide: prefs.data.autoHideHelpers)
        chosen = Set(suggestions.map(\.id))
        appleApps = library.unfiledAppleApps(from: catalog.apps, autoHide: prefs.data.autoHideHelpers)
    }
}

// MARK: Backup

struct BackupSettings: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var library: Library
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Export layout") {
                    Button("Export…") { message = Backup.export(library: library, prefs: prefs) ?? message }
                }
            } footer: {
                Text("Saves your pinned apps, folders, hidden apps, places and appearance to a file. Keep it in OneDrive as a backup, or import it on another Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Import layout") {
                    Button("Import…") { message = Backup.importLayout(library: library, prefs: prefs) ?? message }
                }
            } footer: {
                Text("Replaces your current layout. It's saved to the data folder first, and launch history on this Mac is kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Data folder") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([library.fileURL])
                    }
                }
            }

            if let message {
                Section {
                    Text(message).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: History

struct HistorySettings: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var library: Library
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Stepper(value: $prefs.data.frequentCount, in: 0...20) {
                    LabeledContent("Frequently used apps to show",
                                   value: prefs.data.frequentCount == 0 ? "None" : "\(prefs.data.frequentCount)")
                }
            } footer: {
                Text("Shown under your pinned apps. Set to None to hide the list.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Launch history") {
                    Button("Clear History…") { confirmClear = true }
                }
            } footer: {
                Text("Empties the frequently used list. Pinned apps and folders aren't affected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear the frequently used list?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { library.clearHistory() }
        } message: {
            Text("Apps will reappear as you use them. This can't be undone.")
        }
    }
}

/// One text-size slider with its percentage and a Reset button.
private struct TextSizeRow: View {
    let title: String
    @Binding var scale: Double

    var body: some View {
        // A fixed-width title and a control that fills the rest, so both sliders start and end in the same place.
        LabeledContent {
            HStack(spacing: 10) {
                Text("A").font(.system(size: 11))
                Slider(value: $scale, in: 0.8...1.5, step: 0.05)
                Text("A").font(.system(size: 18))
                Text("\(Int((scale * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                Button("Reset") { scale = 1 }
                    .disabled(scale == 1)
            }
            .frame(maxWidth: .infinity)
        } label: {
            Text(title)
                .frame(width: 90, alignment: .leading)
        }
    }
}
