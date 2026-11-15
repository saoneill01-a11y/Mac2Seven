import AppKit
import UniformTypeIdentifiers

/// Everything that makes up "your layout": pins, folders, hidden apps, places and appearance.
/// Launch history stays on each Mac and isn't exported.
struct LayoutBackup: Codable {
    var format = 1
    var app = "Mac2Seven"
    var exportedAt = Date()
    var library: LibraryData
    var settings: PrefsData
}

@MainActor
enum Backup {
    /// Asks where to save, then writes the layout. Returns a message for the user, or nil if cancelled.
    static func export(library: Library, prefs: Preferences) -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Mac2Seven Layout \(dayStamp()).json"
        panel.directoryURL = OneDrive.bestRoot(OneDrive.roots())
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try write(snapshot(library: library, prefs: prefs), to: url)
            return "Exported to \(url.lastPathComponent)."
        } catch {
            return "Couldn't export: \(error.localizedDescription)"
        }
    }

    /// Asks for a file, confirms, saves the current layout to the data folder, then replaces it.
    static func importLayout(library: Library, prefs: Preferences) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let backup: LayoutBackup
        do {
            backup = try JSONDecoder().decode(LayoutBackup.self, from: Data(contentsOf: url))
            guard backup.app == "Mac2Seven" else { return "That file isn't a Mac2Seven layout." }
        } catch {
            return "That file isn't a Mac2Seven layout, or it's damaged."
        }

        let alert = NSAlert()
        alert.messageText = "Replace your current layout?"
        let date = DateFormatter.localizedString(from: backup.exportedAt, dateStyle: .medium, timeStyle: .short)
        alert.informativeText = """
            Your pinned apps, folders, hidden apps, places and appearance will be replaced with the ones \
            exported on \(date). Your current layout is saved to the data folder first, and launch history \
            on this Mac is kept.
            """
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        // Safety copy of what's being replaced.
        let safety = library.fileURL.deletingLastPathComponent()
            .appendingPathComponent("layout-before-import-\(dayStamp(withTime: true)).json")
        do {
            try write(snapshot(library: library, prefs: prefs), to: safety)
        } catch {
            return "Didn't import: couldn't save your current layout first (\(error.localizedDescription))."
        }

        var incoming = backup.library
        incoming.usage = library.data.usage
        incoming.known = library.data.known
        library.data = incoming
        prefs.data = backup.settings
        return "Imported \(url.lastPathComponent). Your previous layout was saved as \(safety.lastPathComponent)."
    }

    private static func snapshot(library: Library, prefs: Preferences) -> LayoutBackup {
        var lib = library.data
        lib.usage = [:]
        lib.known = [:]
        return LayoutBackup(library: lib, settings: prefs.data)
    }

    private static func write(_ backup: LayoutBackup, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(backup).write(to: url, options: .atomic)
    }

    private static func dayStamp(withTime: Bool = false) -> String {
        let f = DateFormatter()
        f.dateFormat = withTime ? "yyyy-MM-dd-HHmmss" : "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
