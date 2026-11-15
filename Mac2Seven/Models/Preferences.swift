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

struct PrefsData: Codable, Equatable {
    var appearance: AppearanceMode = .system
    var theme: ThemeStyle = .glass
    var useSystemAccent = true
    var accentHex = "#2F7FE0"
    var places: [Place] = PrefsData.defaultPlaces()
    var hotkey: HotkeySpec = .default
    var powerAction: PowerAction = .shutDown
    var frequentCount = 10

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

    let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mac2Seven", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("settings.json")
        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(PrefsData.self, from: raw) {
            data = decoded
        }
    }

    var accentColor: Color {
        data.useSystemAccent ? Color(nsColor: .controlAccentColor) : (Color(hex: data.accentHex) ?? .blue)
    }

    private func save() {
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
