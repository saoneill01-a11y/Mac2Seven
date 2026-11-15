import AppKit

struct Folder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var apps: [String] = []
    var children: [Folder] = []
    /// Developer this folder collects (e.g. "com.microsoft"); new apps from them are filed here automatically.
    var developer: String? = nil
}

struct Usage: Codable, Hashable {
    var count: Int
    var last: Date
}

struct LibraryData: Codable {
    var pinned: [String] = []
    var folders: [Folder] = []
    var usage: [String: Usage] = [:]
    /// Custom order of the apps at the top level of All Programs. Empty means alphabetical.
    var rootOrder: [String] = []
    /// Apps the user hid.
    var hidden: [String] = []
    /// Apps the user unhid or placed themselves; never auto-hidden again.
    var unhidden: [String] = []
    /// When each app was first seen (distant past for apps already installed or launched), for the New badge.
    var known: [String: Date] = [:]

    init() {}

    // Tolerates keys added in later versions so an older settings file still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? []
        folders = try c.decodeIfPresent([Folder].self, forKey: .folders) ?? []
        usage = try c.decodeIfPresent([String: Usage].self, forKey: .usage) ?? [:]
        rootOrder = try c.decodeIfPresent([String].self, forKey: .rootOrder) ?? []
        hidden = (try? c.decodeIfPresent([String].self, forKey: .hidden)) ?? []
        unhidden = (try? c.decodeIfPresent([String].self, forKey: .unhidden)) ?? []
        known = (try? c.decodeIfPresent([String: Date].self, forKey: .known)) ?? [:]
    }
}

/// Which side of a row a dragged app was dropped on.
enum DropEdge {
    case before, after
}

struct FolderEntry: Identifiable {
    let folder: Folder
    let depth: Int
    var id: UUID { folder.id }
}

/// The user's pinned apps, folders and launch history, saved as JSON in Application Support.
@MainActor
final class Library: ObservableObject {
    @Published var data = LibraryData() {
        didSet { scheduleSave() }
    }

    let fileURL: URL
    private var saveWork: DispatchWorkItem?
    private var lastRecord: (path: String, time: Date)?
    private let ownPath = Bundle.main.bundlePath

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mac2Seven", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("library.json")
    }

    // MARK: Persistence

    func load() {
        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(LibraryData.self, from: raw) {
            data = decoded
        } else {
            data = Self.seed()
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = data
        let url = fileURL
        let work = DispatchWorkItem {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let raw = try? encoder.encode(snapshot) {
                try? raw.write(to: url, options: .atomic)
            }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private static func seed() -> LibraryData {
        let fm = FileManager.default
        var seeded = LibraryData()
        seeded.pinned = [
            "/Applications/Safari.app",
            "/System/Applications/Mail.app",
            "/System/Library/CoreServices/Finder.app",
            "/System/Applications/Calendar.app",
            "/System/Applications/Notes.app",
        ].filter { fm.fileExists(atPath: $0) }

        let utilDir = "/System/Applications/Utilities"
        let utils = ((try? fm.contentsOfDirectory(atPath: utilDir)) ?? [])
            .filter { $0.hasSuffix(".app") }
            .sorted()
            .map { utilDir + "/" + $0 }
        seeded.folders = [Folder(name: "Utilities", apps: utils)]

        // Start the "frequently used" list with whatever is open right now.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let path = app.bundleURL?.path, path != Bundle.main.bundlePath, !seeded.pinned.contains(path) {
                seeded.usage[path] = Usage(count: 1, last: Date())
            }
        }
        return seeded
    }

    // MARK: Launching and history

    func startTracking() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular,
                  let path = app.bundleURL?.path else { return }
            MainActor.assumeIsolated { self?.record(path) }
        }
    }

    func record(_ path: String) {
        guard path != ownPath else { return }
        if let last = lastRecord, last.path == path, Date().timeIntervalSince(last.time) < 5 { return }
        lastRecord = (path, Date())
        var d = data
        var usage = d.usage[path] ?? Usage(count: 0, last: .distantPast)
        usage.count += 1
        usage.last = Date()
        d.usage[path] = usage
        // Opening an app clears its New badge.
        if d.known[path] != nil { d.known[path] = .distantPast }
        data = d
    }

    func launch(_ path: String) {
        record(path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config)
    }

    /// Frequently used apps, ranked by launch count with older launches fading out.
    func frequent(limit: Int = 10, excluding isHidden: (String) -> Bool = { _ in false }) -> [String] {
        let now = Date()
        let pinned = Set(data.pinned)
        func score(_ u: Usage) -> Double {
            let days = max(0, now.timeIntervalSince(u.last) / 86_400)
            return Double(u.count) * exp(-days / 10) + 2 * exp(-days)
        }
        return data.usage
            .filter { !pinned.contains($0.key) && !isHidden($0.key) && FileManager.default.fileExists(atPath: $0.key) }
            .sorted { score($0.value) > score($1.value) }
            .prefix(limit)
            .map(\.key)
    }

    func forget(_ path: String) {
        data.usage[path] = nil
    }

    /// Empties the frequently used list (pins and folders are untouched).
    func clearHistory() {
        data.usage = [:]
    }

    // MARK: Hiding

    /// Whole words that mark an app as a helper rather than something you open yourself.
    static let helperWords: Set<String> = [
        "helper", "server", "service", "shim", "agent", "daemon",
        "installer", "uninstaller", "uninstall", "updater",
    ]

    /// "3DconnexionHelper" → words "3dconnexion", "helper" → true. "Autodesk Fusion" → false.
    static func looksLikeHelper(_ name: String) -> Bool {
        let spaced = name.replacingOccurrences(
            of: "(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", with: " ", options: .regularExpression)
        let words = spaced.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if let first = words.first, first == "remove" || first == "uninstall" { return true }
        return words.contains { helperWords.contains($0) }
    }

    /// Hidden by the user, or auto-hidden as a helper (unless pinned, filed in a folder, or unhidden by the user).
    func isHidden(_ item: AppItem, autoHide: Bool) -> Bool {
        if data.hidden.contains(item.path) { return true }
        guard autoHide, Self.looksLikeHelper(item.name) else { return false }
        return !isPinned(item.path) && folderContaining(item.path) == nil && !data.unhidden.contains(item.path)
    }

    func isManuallyHidden(_ path: String) -> Bool { data.hidden.contains(path) }

    /// Hides an app: takes it off the pinned list and out of any folder.
    func hide(_ path: String) {
        var d = data
        d.pinned.removeAll { $0 == path }
        func strip(_ list: inout [Folder]) {
            for i in list.indices {
                list[i].apps.removeAll { $0 == path }
                strip(&list[i].children)
            }
        }
        strip(&d.folders)
        d.unhidden.removeAll { $0 == path }
        if !d.hidden.contains(path) { d.hidden.append(path) }
        data = d
    }

    func unhide(_ path: String) {
        var d = data
        d.hidden.removeAll { $0 == path }
        if !d.unhidden.contains(path) { d.unhidden.append(path) }
        data = d
    }

    /// Apps the user places by hand count as wanted: un-hide them and keep them visible from now on.
    private func reveal(_ paths: [String]) {
        var d = data
        var changed = false
        for path in paths {
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            if d.hidden.contains(path) {
                d.hidden.removeAll { $0 == path }
                changed = true
            } else if !Self.looksLikeHelper(name) {
                continue
            }
            if !d.unhidden.contains(path) {
                d.unhidden.append(path)
                changed = true
            }
        }
        if changed { data = d }
    }

    // MARK: New apps

    static let newBadgeDuration: TimeInterval = 7 * 86_400

    func isNew(_ path: String) -> Bool {
        guard let first = data.known[path] else { return false }
        return Date().timeIntervalSince(first) < Self.newBadgeDuration
    }

    /// Called after each scan: notes newly installed apps (for the New badge) and files them into
    /// their developer's folder when there is one. On the very first scan everything counts as old.
    func noteScan(_ apps: [AppItem]) {
        var d = data
        let firstRun = d.known.isEmpty
        var added: [AppItem] = []
        for app in apps where d.known[app.path] == nil {
            d.known[app.path] = firstRun ? .distantPast : Date()
            if !firstRun { added.append(app) }
        }
        guard d.known.count != data.known.count else { return }
        data = d

        for app in added where !data.hidden.contains(app.path) && !Self.looksLikeHelper(app.name)
            && folderContaining(app.path) == nil {
            if let key = Self.developerKey(app.bundleID), let folder = folderForDeveloper(key) {
                move([app.path], to: folder)
            }
        }
    }

    // MARK: Organize by developer

    /// "com.microsoft.Word" → "com.microsoft". Apple's own apps and Chrome web-app wrappers aren't grouped.
    static func developerKey(_ bundleID: String?) -> String? {
        guard let id = bundleID?.lowercased(),
              !id.hasPrefix("com.apple."), !id.hasPrefix("com.google.chrome.app.") else { return nil }
        let parts = id.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return parts[0] + "." + parts[1]
    }

    static let knownDevelopers: [String: String] = [
        "com.microsoft": "Microsoft", "com.google": "Google", "com.adobe": "Adobe",
        "com.autodesk": "Autodesk", "com.logi": "Logitech", "com.logitech": "Logitech",
        "com.bambulab": "Bambu Lab", "com.3dconnexion": "3Dconnexion", "com.mspanywhere": "MSP Anywhere",
        "com.jetbrains": "JetBrains", "com.splashtop": "Splashtop", "us.zoom": "Zoom",
    ]

    static func suggestedName(_ key: String) -> String {
        if let known = knownDevelopers[key] { return known }
        let part = key.split(separator: ".").last.map(String.init) ?? key
        return part.prefix(1).uppercased() + part.dropFirst()
    }

    func folderForDeveloper(_ key: String) -> UUID? {
        flatFolders().first { $0.folder.developer == key }?.folder.id
    }

    struct FolderSuggestion: Identifiable {
        let id: String          // developer key
        var name: String
        let apps: [AppItem]     // apps that would move
        let existing: UUID?     // folder they'd join, if one already holds this developer's apps
        let existingName: String?
    }

    /// Developers with apps that aren't in a folder yet. Joins an existing folder when one already
    /// holds that developer's apps; otherwise suggests a new folder (only when there are 2+ apps).
    func suggestions(from apps: [AppItem], autoHide: Bool) -> [FolderSuggestion] {
        let folders = flatFolders()
        var groups: [String: [AppItem]] = [:]
        for app in apps where !isHidden(app, autoHide: autoHide) {
            if let key = Self.developerKey(app.bundleID) { groups[key, default: []].append(app) }
        }
        var result: [FolderSuggestion] = []
        for (key, group) in groups {
            let unfiled = group.filter { folderContaining($0.path) == nil }
            guard !unfiled.isEmpty else { continue }
            var existing = folderForDeveloper(key)
            if existing == nil {
                // The folder already holding most of this developer's apps.
                let counts = Dictionary(grouping: group.compactMap { folderContaining($0.path) }, by: { $0 })
                existing = counts.max { $0.value.count < $1.value.count }?.key
            }
            if existing == nil && unfiled.count < 2 { continue }
            let existingName = existing.flatMap { id in folders.first { $0.folder.id == id }?.folder.name }
            result.append(FolderSuggestion(id: key, name: existingName ?? Self.suggestedName(key),
                                           apps: unfiled, existing: existing, existingName: existingName))
        }
        return result.sorted { $0.apps.count != $1.apps.count ? $0.apps.count > $1.apps.count : $0.name < $1.name }
    }

    /// Creates (or fills) the chosen folders and remembers each folder's developer for future installs.
    func applySuggestions(_ chosen: [FolderSuggestion]) {
        for suggestion in chosen {
            let name = suggestion.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = suggestion.existing ?? addFolder(parent: nil, name: name.isEmpty ? Self.suggestedName(suggestion.id) : name)
            _ = Self.mutate(&data.folders, id: id) { $0.developer = suggestion.id }
            move(suggestion.apps.map(\.path), to: id)
        }
    }

    // MARK: Pins

    func isPinned(_ path: String) -> Bool { data.pinned.contains(path) }

    func pin(_ path: String) {
        guard !isPinned(path) else { return }
        reveal([path])
        data.pinned.append(path)
    }

    func unpin(_ path: String) {
        data.pinned.removeAll { $0 == path }
    }

    /// Pins (or reorders) apps next to `target`, or at the end when there is no target.
    func placePins(_ paths: [String], relativeTo target: String?, edge: DropEdge) {
        guard !paths.isEmpty else { return }
        reveal(paths)
        if let target, paths.contains(target) { return } // dropped onto itself
        var pins = data.pinned.filter { !paths.contains($0) }
        pins.insert(contentsOf: paths, at: Self.insertionIndex(in: pins, target: target, edge: edge))
        data.pinned = pins
    }

    private static func insertionIndex(in list: [String], target: String?, edge: DropEdge) -> Int {
        guard let target, let i = list.firstIndex(of: target) else { return list.endIndex }
        return edge == .before ? i : i + 1
    }

    // MARK: Folders

    var filedPaths: Set<String> {
        var set = Set<String>()
        func collect(_ folders: [Folder]) {
            for f in folders {
                set.formUnion(f.apps)
                collect(f.children)
            }
        }
        collect(data.folders)
        return set
    }

    func folderContaining(_ path: String) -> UUID? {
        func find(_ folders: [Folder]) -> UUID? {
            for f in folders {
                if f.apps.contains(path) { return f.id }
                if let id = find(f.children) { return id }
            }
            return nil
        }
        return find(data.folders)
    }

    func flatFolders() -> [FolderEntry] {
        var out: [FolderEntry] = []
        func walk(_ folders: [Folder], _ depth: Int) {
            for f in folders {
                out.append(FolderEntry(folder: f, depth: depth))
                walk(f.children, depth + 1)
            }
        }
        walk(data.folders, 0)
        return out
    }

    @discardableResult
    func addFolder(parent: UUID?, name: String = "New Folder") -> UUID {
        let folder = Folder(name: name)
        if let parent {
            _ = Self.mutate(&data.folders, id: parent) { $0.children.append(folder) }
        } else {
            data.folders.append(folder)
        }
        return folder.id
    }

    func renameFolder(_ id: UUID, to name: String) {
        _ = Self.mutate(&data.folders, id: id) { $0.name = name }
    }

    /// Sorts a folder's apps by name, A to Z (and its subfolders, which always sit above the apps).
    func sortFolder(_ id: UUID) {
        func name(_ path: String) -> String {
            let display = FileManager.default.displayName(atPath: path)
            return display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        }
        _ = Self.mutate(&data.folders, id: id) { folder in
            folder.apps.sort { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
            folder.children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// Deletes a folder and its subfolders. Their apps go back to the top level of All Programs.
    func deleteFolder(_ id: UUID) {
        func remove(_ folders: inout [Folder]) {
            folders.removeAll { $0.id == id }
            for i in folders.indices { remove(&folders[i].children) }
        }
        remove(&data.folders)
    }

    func move(_ path: String, to folderID: UUID?) {
        move([path], to: folderID)
    }

    /// Files apps into a folder next to `target` (or at the end), or back to the top level when `folderID` is nil.
    func move(_ paths: [String], to folderID: UUID?, relativeTo target: String? = nil, edge: DropEdge = .after) {
        guard !paths.isEmpty else { return }
        reveal(paths)
        if let target, paths.contains(target) { return } // dropped onto itself
        var folders = data.folders
        func strip(_ list: inout [Folder]) {
            for i in list.indices {
                list[i].apps.removeAll { paths.contains($0) }
                strip(&list[i].children)
            }
        }
        strip(&folders)
        if let folderID {
            _ = Self.mutate(&folders, id: folderID) { folder in
                let index = Self.insertionIndex(in: folder.apps, target: target, edge: edge)
                folder.apps.insert(contentsOf: paths, at: index)
            }
        }
        data.folders = folders
    }

    // MARK: All Programs ordering

    /// Apps not in any folder, in the user's order (apps never placed by hand follow alphabetically).
    func looseApps(from apps: [AppItem]) -> [AppItem] {
        let filed = filedPaths
        let loose = apps.filter { !filed.contains($0.path) }
        guard !data.rootOrder.isEmpty else { return loose }
        let byPath = Dictionary(loose.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var ordered = data.rootOrder.compactMap { byPath[$0] }
        let placed = Set(ordered.map(\.path))
        ordered += loose.filter { !placed.contains($0.path) }
        return ordered
    }

    /// Places apps at the top level of All Programs next to `target`, taking them out of any folder.
    /// `current` is the top-level order as currently shown.
    func placeAtTop(_ paths: [String], relativeTo target: String, edge: DropEdge, current: [String]) {
        guard !paths.isEmpty, !paths.contains(target) else { return }
        move(paths, to: nil)
        var order = current.filter { !paths.contains($0) }
        order.insert(contentsOf: paths, at: Self.insertionIndex(in: order, target: target, edge: edge))
        data.rootOrder = order
    }

    /// Moves a folder to sit just before or after another folder (at that folder's level).
    func placeFolder(_ id: UUID, relativeTo target: UUID, edge: DropEdge) {
        guard id != target, !isDescendant(target, of: id) else { return }
        var folders = data.folders
        guard let moving = Self.removeFolder(id, from: &folders) else { return }
        if !Self.insertFolder(moving, near: target, edge: edge, in: &folders) {
            folders.append(moving)
        }
        data.folders = folders
    }

    /// Moves a folder inside another folder, or to the end of the top level when `parent` is nil.
    func nestFolder(_ id: UUID, into parent: UUID?) {
        if let parent, parent == id || isDescendant(parent, of: id) { return }
        var folders = data.folders
        guard let moving = Self.removeFolder(id, from: &folders) else { return }
        if let parent {
            _ = Self.mutate(&folders, id: parent) { $0.children.append(moving) }
        } else {
            folders.append(moving)
        }
        data.folders = folders
    }

    /// True when `id` is somewhere inside the folder `ancestor`.
    func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool {
        func contains(_ list: [Folder]) -> Bool {
            list.contains { $0.id == id || contains($0.children) }
        }
        func find(_ list: [Folder]) -> Folder? {
            for f in list {
                if f.id == ancestor { return f }
                if let hit = find(f.children) { return hit }
            }
            return nil
        }
        guard let root = find(data.folders) else { return false }
        return contains(root.children)
    }

    private static func removeFolder(_ id: UUID, from list: inout [Folder]) -> Folder? {
        if let i = list.firstIndex(where: { $0.id == id }) { return list.remove(at: i) }
        for i in list.indices {
            if let found = removeFolder(id, from: &list[i].children) { return found }
        }
        return nil
    }

    private static func insertFolder(_ folder: Folder, near target: UUID, edge: DropEdge, in list: inout [Folder]) -> Bool {
        if let i = list.firstIndex(where: { $0.id == target }) {
            list.insert(folder, at: edge == .before ? i : i + 1)
            return true
        }
        for i in list.indices {
            if insertFolder(folder, near: target, edge: edge, in: &list[i].children) { return true }
        }
        return false
    }

    private static func mutate(_ folders: inout [Folder], id: UUID, _ body: (inout Folder) -> Void) -> Bool {
        for i in folders.indices {
            if folders[i].id == id {
                body(&folders[i])
                return true
            }
            if mutate(&folders[i].children, id: id, body) { return true }
        }
        return false
    }
}
