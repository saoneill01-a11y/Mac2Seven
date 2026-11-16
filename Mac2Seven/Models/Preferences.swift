import AppKit
import Carbon.HIToolbox
import SwiftUI

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

enum ThemeStyle: String, Codable, CaseIterable, Identifiable {
    case glass, flat
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: return "Glass"
        case .flat: return "Flat"
        }
    }
    var summary: String {
        switch self {
        case .glass: return "Translucent blur, soft highlights and rounded corners."
        case .flat: return "Solid panels, square corners and bold accent highlights."
        }
    }
}

/// A global keyboard shortcut (Carbon key code and modifiers) plus how to show it.
struct HotkeySpec: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static let `default` = HotkeySpec(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), display: "⌥Space")
    static let snip = HotkeySpec(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | shiftKey), display: "⌥⇧S")
}

enum SnipMode: String, Codable, CaseIterable, Identifiable {
    case rectangle, window, fullScreen, freeform
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .window: return "Window"
        case .fullScreen: return "Full screen"
        case .freeform: return "Freeform"
        }
    }
    var symbol: String {
        switch self {
        case .rectangle: return "rectangle.dashed"
        case .window: return "macwindow"
        case .fullScreen: return "display"
        case .freeform: return "scribble"
        }
    }
}

struct SnipSettings: Codable, Equatable {
    var hotkey: HotkeySpec = .snip
    var saveFolder: String = FileManager.default.homeDirectoryForCurrentUser.path + "/Pictures/Screenshots"
    var autoSave = true
    var copyToClipboard = true
    var openInPreview = true
    var showThumbnail = true
    var showPointer = false
    var windowShadow = true
    var taskbarButton = true
    var mode: SnipMode = .rectangle
    var delay = 0
    /// The last rectangle captured (in its display's points, origin bottom-left) and that display's ID,
    /// so Rectangle mode can start with it already drawn.
    var lastRect: CGRect?
    var lastRectDisplay: UInt32?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SnipSettings()
        hotkey = (try? c.decodeIfPresent(HotkeySpec.self, forKey: .hotkey)) ?? d.hotkey
        saveFolder = (try? c.decodeIfPresent(String.self, forKey: .saveFolder)) ?? d.saveFolder
        autoSave = (try? c.decodeIfPresent(Bool.self, forKey: .autoSave)) ?? d.autoSave
        copyToClipboard = (try? c.decodeIfPresent(Bool.self, forKey: .copyToClipboard)) ?? d.copyToClipboard
        openInPreview = (try? c.decodeIfPresent(Bool.self, forKey: .openInPreview)) ?? d.openInPreview
        showThumbnail = (try? c.decodeIfPresent(Bool.self, forKey: .showThumbnail)) ?? d.showThumbnail
        showPointer = (try? c.decodeIfPresent(Bool.self, forKey: .showPointer)) ?? d.showPointer
        windowShadow = (try? c.decodeIfPresent(Bool.self, forKey: .windowShadow)) ?? d.windowShadow
        taskbarButton = (try? c.decodeIfPresent(Bool.self, forKey: .taskbarButton)) ?? d.taskbarButton
        mode = (try? c.decodeIfPresent(SnipMode.self, forKey: .mode)) ?? d.mode
        delay = (try? c.decodeIfPresent(Int.self, forKey: .delay)) ?? d.delay
        lastRect = try? c.decodeIfPresent(CGRect.self, forKey: .lastRect)
        lastRectDisplay = try? c.decodeIfPresent(UInt32.self, forKey: .lastRectDisplay)
    }
}

/// One entry in the right-hand column: a folder or app to open, or a separator line.
struct Place: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var path: String
    var bold = false
    var isSeparator = false

    var url: URL { URL(fileURLWithPath: path) }

    static func separator() -> Place { Place(title: "", path: "", isSeparator: true) }
}

enum TaskbarAlignment: String, Codable, CaseIterable, Identifiable {
    case center, left
    var id: String { rawValue }
    var title: String { self == .center ? "Center" : "Left" }
}

enum TaskbarButtons: String, Codable, CaseIterable, Identifiable {
    case combine, combineLabels, labels
    var id: String { rawValue }
    var title: String {
        switch self {
        case .combine: return "Combine (icons only)"
        case .combineLabels: return "Combine (with app names)"
        case .labels: return "Never combine (window titles)"
        }
    }
}

enum CalendarStyle: String, Codable, CaseIterable, Identifiable {
    case glass, windows, compact
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: return "Mac2Seven glass"
        case .windows: return "Windows 11"
        case .compact: return "Compact"
        }
    }
}

struct TaskbarSettings: Codable, Equatable {
    var enabled = false
    var alignment: TaskbarAlignment = .center
    var rows = 1
    var buttons: TaskbarButtons = .combine
    var allDisplays = true
    var keepWindowsClear = true
    var showPreviews = true
    var hideWindowless = false
    var calendarStyle: CalendarStyle = .glass
    var pinned: [String] = TaskbarSettings.defaultPins()
    /// The order of the taskbar's app buttons (pinned and running), as set by dragging. Empty means
    /// pinned apps in pin order, then running apps in the order they opened.
    var order: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TaskbarSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        alignment = (try? c.decodeIfPresent(TaskbarAlignment.self, forKey: .alignment)) ?? d.alignment
        rows = min(max((try? c.decodeIfPresent(Int.self, forKey: .rows)) ?? d.rows, 1), 3)
        buttons = (try? c.decodeIfPresent(TaskbarButtons.self, forKey: .buttons)) ?? d.buttons
        allDisplays = (try? c.decodeIfPresent(Bool.self, forKey: .allDisplays)) ?? d.allDisplays
        keepWindowsClear = (try? c.decodeIfPresent(Bool.self, forKey: .keepWindowsClear)) ?? d.keepWindowsClear
        showPreviews = (try? c.decodeIfPresent(Bool.self, forKey: .showPreviews)) ?? d.showPreviews
        hideWindowless = (try? c.decodeIfPresent(Bool.self, forKey: .hideWindowless)) ?? d.hideWindowless
        calendarStyle = (try? c.decodeIfPresent(CalendarStyle.self, forKey: .calendarStyle)) ?? d.calendarStyle
        pinned = (try? c.decodeIfPresent([String].self, forKey: .pinned)) ?? d.pinned
        order = (try? c.decodeIfPresent([String].self, forKey: .order)) ?? d.order
    }

    static func defaultPins() -> [String] {
        ["/System/Library/CoreServices/Finder.app", "/Applications/Safari.app", "/System/Applications/Mail.app",
         "/System/Applications/Calendar.app", "/System/Applications/Messages.app", "/System/Applications/Music.app"]
            .filter { FileManager.default.fileExists(atPath: $0) }
    }
}

struct PrefsData: Codable, Equatable {
    var appearance: AppearanceMode = .system
    var theme: ThemeStyle = .glass
    var useSystemAccent = true
    var accentHex = "#2F7FE0"
    var places: [Place] = PrefsData.defaultPlaces()
    var hotkey: HotkeySpec = .default
    var powerAction: PowerAction = .shutDown
    var frequentCount = 10
    var autoHideHelpers = true
    var taskbar = TaskbarSettings()
    var snip = SnipSettings()
    /// Text size in the Start menu, as a multiple of the normal size.
    var textScale: Double = 1.0
    /// Text size on the taskbar, as a multiple of the normal size.
    var taskbarTextScale: Double = 1.0
    /// The Start menu's size, set by dragging its resize grip.
    var menuWidth: Double = 580
    var menuHeight: Double = 620

    init() {}

    // Missing or unreadable keys fall back to defaults, so adding settings later never wipes the file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrefsData()
        appearance = (try? c.decodeIfPresent(AppearanceMode.self, forKey: .appearance)) ?? d.appearance
        theme = (try? c.decodeIfPresent(ThemeStyle.self, forKey: .theme)) ?? d.theme
        useSystemAccent = (try? c.decodeIfPresent(Bool.self, forKey: .useSystemAccent)) ?? d.useSystemAccent
        accentHex = (try? c.decodeIfPresent(String.self, forKey: .accentHex)) ?? d.accentHex
        places = (try? c.decodeIfPresent([Place].self, forKey: .places)) ?? d.places
        hotkey = (try? c.decodeIfPresent(HotkeySpec.self, forKey: .hotkey)) ?? d.hotkey
        powerAction = (try? c.decodeIfPresent(PowerAction.self, forKey: .powerAction)) ?? d.powerAction
        frequentCount = (try? c.decodeIfPresent(Int.self, forKey: .frequentCount)) ?? d.frequentCount
        autoHideHelpers = (try? c.decodeIfPresent(Bool.self, forKey: .autoHideHelpers)) ?? d.autoHideHelpers
        taskbar = (try? c.decodeIfPresent(TaskbarSettings.self, forKey: .taskbar)) ?? d.taskbar
        snip = (try? c.decodeIfPresent(SnipSettings.self, forKey: .snip)) ?? d.snip
        textScale = min(max((try? c.decodeIfPresent(Double.self, forKey: .textScale)) ?? d.textScale, 0.8), 1.5)
        // Until 1.3.1 one setting covered both; carry it over to the taskbar.
        taskbarTextScale = min(max((try? c.decodeIfPresent(Double.self, forKey: .taskbarTextScale)) ?? textScale, 0.8), 1.5)
        menuWidth = max((try? c.decodeIfPresent(Double.self, forKey: .menuWidth)) ?? d.menuWidth, 480)
        menuHeight = max((try? c.decodeIfPresent(Double.self, forKey: .menuHeight)) ?? d.menuHeight, 460)
    }

    static func defaultPlaces() -> [Place] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let name = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
        return [
            Place(title: name, path: home, bold: true),
            Place(title: "Documents", path: home + "/Documents"),
            Place(title: "Pictures", path: home + "/Pictures"),
            Place(title: "Music", path: home + "/Music"),
            Place(title: "Downloads", path: home + "/Downloads"),
            .separator(),
            Place(title: "Computer", path: "/"),
            Place(title: "Applications", path: "/Applications"),
            .separator(),
            Place(title: "System Settings", path: "/System/Applications/System Settings.app"),
            Place(title: "Activity Monitor", path: "/System/Applications/Utilities/Activity Monitor.app"),
        ]
    }
}

/// App settings, saved as JSON next to the library (kept separate so a settings problem can't touch pins or folders).
@MainActor
final class Preferences: ObservableObject {
    @Published var data = PrefsData() {
        didSet { if data != oldValue { save() } }
    }
    /// True while the shortcut recorder is listening, so the current shortcut doesn't fire.
    @Published var isRecordingHotkey = false
    /// Which Settings tab is showing (not saved).
    @Published var settingsTab = "general"

    let fileURL: URL

    init() {
        let dir = DataFolder.url
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let raw = try? Data(contentsOf: fileURL),
               let decoded = try? JSONDecoder().decode(PrefsData.self, from: raw) {
                data = decoded
            } else if let moved = SafeFile.setAside(fileURL) {
                recoveredFile = moved
            } else {
                saveDisabled = true
            }
        }
    }

    /// Set when settings.json couldn't be read and was set aside under this name.
    private(set) var recoveredFile: URL?
    private var saveDisabled = false

    var accentColor: Color {
        data.useSystemAccent ? Color(nsColor: .controlAccentColor) : (Color(hex: data.accentHex) ?? .blue)
    }

    private func save() {
        guard !saveDisabled else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let raw = try? encoder.encode(data) {
            try? raw.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: OneDrive

enum OneDrive {
    /// Folders swapped between the Mac and OneDrive versions.
    static let swappable = ["Documents", "Pictures", "Desktop"]

    /// OneDrive roots synced to this Mac, e.g. ~/Library/CloudStorage/OneDrive-CSI.
    static func roots() -> [URL] {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries
            .filter { $0.lastPathComponent.hasPrefix("OneDrive") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The account to suggest: the one with the most of Documents/Pictures/Desktop synced.
    static func bestRoot(_ roots: [URL]) -> URL? {
        let fm = FileManager.default
        func score(_ root: URL) -> Int {
            swappable.filter { fm.fileExists(atPath: root.appendingPathComponent($0).path) }.count
        }
        return roots.max { score($0) < score($1) }
    }

    /// "OneDrive-CSI" → "OneDrive – CSI".
    static func displayName(_ root: URL) -> String {
        let name = root.lastPathComponent
        guard let dash = name.firstIndex(of: "-") else { return name }
        return name[..<dash] + " – " + name[name.index(after: dash)...]
    }

    static func isUsing(_ places: [Place]) -> Bool {
        places.contains { $0.path.contains("/Library/CloudStorage/OneDrive") }
    }

    /// Points Documents/Pictures/Desktop at the OneDrive versions (where they exist) and adds a OneDrive entry.
    static func apply(root: URL, to places: [Place]) -> [Place] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var result = revert(places)
        for i in result.indices {
            for name in swappable where result[i].path == home + "/" + name {
                let target = root.appendingPathComponent(name).path
                if fm.fileExists(atPath: target) { result[i].path = target }
            }
        }
        if !result.contains(where: { $0.path == root.path }) {
            // Right after the personal folders at the top (before the first separator).
            let index = result.firstIndex(where: \.isSeparator) ?? result.endIndex
            result.insert(Place(title: "OneDrive", path: root.path), at: index)
        }
        return result
    }

    /// Puts the Mac folders back and removes OneDrive root entries.
    static func revert(_ places: [Place]) -> [Place] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = Set(roots().map(\.path))
        var result = places.filter { !roots.contains($0.path) }
        for i in result.indices {
            for root in roots {
                for name in swappable where result[i].path == root + "/" + name {
                    result[i].path = home + "/" + name
                }
            }
        }
        return result
    }
}

// MARK: Color hex

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

// MARK: Safe files

enum SafeFile {
    /// Renames an unreadable data file to "<name>.unreadable-<date>.json" so it isn't overwritten.
    static func setAside(_ url: URL) -> URL? {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let base = url.deletingPathExtension().lastPathComponent
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(base).unreadable-\(stamp.string(from: Date())).json")
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            NSLog("Mac2Seven couldn't set aside \(url.path): \(error)")
            return nil
        }
    }
}
