import AppKit

/// One launchable application on disk.
struct AppItem: Identifiable, Hashable {
    let path: String
    let name: String
    var bundleID: String? = nil
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

/// Scans the usual application folders and keeps an alphabetical list of apps.
@MainActor
final class AppCatalog: ObservableObject {
    @Published private(set) var apps: [AppItem] = []
    private var byPath: [String: AppItem] = [:]
    private var scanning = false
    /// Called with the full list after every scan (used to spot newly installed apps).
    var onScan: (([AppItem]) -> Void)?

    func refresh() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .userInitiated) {
            let found = AppCatalog.scan()
            await MainActor.run {
                self.apps = found
                self.byPath = Dictionary(found.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                self.scanning = false
                self.onScan?(found)
            }
        }
    }

    /// Looks up an app by path, falling back to reading it from disk (for apps outside the scanned folders).
    func item(for path: String) -> AppItem? {
        byPath[path] ?? AppCatalog.makeItem(path)
    }

    nonisolated static func scan() -> [AppItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let roots = ["/Applications", "/System/Applications", home + "/Applications"]
        let ownPath = Bundle.main.bundlePath
        var result: [String: AppItem] = [:]

        func walk(_ dir: String, depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for entry in entries where !entry.hasPrefix(".") {
                let path = (dir as NSString).appendingPathComponent(entry)
                if entry.hasSuffix(".app") {
                    if path != ownPath, let item = makeItem(path) { result[path] = item }
                } else if depth > 0 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                        walk(path, depth: depth - 1)
                    }
                }
            }
        }

        roots.forEach { walk($0, depth: 2) }
        let finder = "/System/Library/CoreServices/Finder.app"
        if let item = makeItem(finder) { result[finder] = item }

        return result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static func makeItem(_ path: String) -> AppItem? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return AppItem(path: path, name: name, bundleID: Bundle(path: path)?.bundleIdentifier)
    }
}

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}
