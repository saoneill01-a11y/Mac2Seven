import AppKit
import SwiftUI

/// Shared UI state for the open menu.
@MainActor
final class MenuState: ObservableObject {
    @Published var query = ""
    @Published var showingAll = false
    @Published var selection = 0
    @Published var openToken = 0
    /// Path whose icon replaces the user picture while hovering (like the classic menu did).
    @Published var hoverIconPath: String?
    /// True while something is being dragged over or out of the menu; hover highlights are hidden then
    /// so only the blue insertion line shows.
    @Published private(set) var isDragging = false
    /// The one row the mouse is over. Kept here (not per row) so a stale highlight can't linger.
    @Published var hoveredID: String?
    /// The one place the insertion line is drawn. Kept here so only one line can ever show.
    @Published var dropLine: DropLine?
    var hitCount = 0
    var closeHandler: () -> Void = {}

    struct DropLine: Equatable {
        let id: String
        let edge: DropEdge
    }

    func close() { closeHandler() }

    func setHover(_ id: String, _ inside: Bool) {
        if inside {
            guard !isDragging, hoveredID != id else { return }
            hoveredID = id
        } else if hoveredID == id {
            hoveredID = nil
        }
    }

    // MARK: Drag session

    /// What is being dragged out of the menu (nil for drags coming in from Finder).
    @Published private(set) var dragPayload: DropPayload?
    /// Used to put things back if a drag that moved items live is cancelled.
    weak var library: Library?
    /// Scrolls the list when a drag goes near or past its top or bottom.
    let autoScroller = AutoScroller()
    private var snapshot: LibraryData?
    private var movedLive = false
    private var committed = false

    func beginDrag(_ payload: DropPayload?) {
        if isDragging {
            if dragPayload == nil, let payload { dragPayload = payload }
            return
        }
        isDragging = true
        dragPayload = payload
        hoveredID = nil
        hoverIconPath = nil
        snapshot = library?.data
        movedLive = false
        committed = false
        autoScroller.start()
        watchForDragEnd()
    }

    func markLiveMove() { movedLive = true }

    /// Called when a drop lands on the menu, so the live changes are kept.
    func commitDrag() { committed = true }

    private func endDrag() {
        autoScroller.stop()
        if movedLive, !committed, let snapshot {
            withAnimation(.easeOut(duration: 0.15)) { library?.data = snapshot }
        }
        snapshot = nil
        dragPayload = nil
        isDragging = false
        dropLine = nil
    }

    /// SwiftUI doesn't report when a drag ends (dropped or cancelled), so watch the mouse button
    /// at the hardware level, which stays accurate while a drag is in progress.
    private func watchForDragEnd() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.isDragging else { return }
            if CGEventSource.buttonState(.combinedSessionState, button: .left) {
                self.watchForDragEnd()
            } else {
                self.endDrag()
            }
        }
    }

    func reset() {
        query = ""
        showingAll = false
        selection = 0
        hoverIconPath = nil
        hoveredID = nil
        dropLine = nil
        openToken += 1
    }
}

enum SearchHit: Identifiable {
    case app(AppItem)
    case file(URL)

    var id: String {
        switch self {
        case .app(let a): return "a:" + a.path
        case .file(let u): return "f:" + u.path
        }
    }

    static func compute(query: String, apps: [AppItem], files: [URL]) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let lower = q.lowercased()
        let matched = apps
            .filter { $0.name.localizedCaseInsensitiveContains(q) }
            .sorted { a, b in
                let ap = a.name.lowercased().hasPrefix(lower), bp = b.name.lowercased().hasPrefix(lower)
                if ap != bp { return ap }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            .prefix(8)
        return matched.map { .app($0) } + files.prefix(8).map { .file($0) }
    }
}

/// Spotlight search over the user's home folder for files whose name matches.
@MainActor
final class FileSearch: ObservableObject {
    @Published private(set) var results: [URL] = []
    private let query = NSMetadataQuery()

    init() {
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.collect() }
            }
        }
    }

    func search(_ text: String) {
        query.stop()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            results = []
            return
        }
        query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, q)
        query.start()
    }

    private func collect() {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var urls: [URL] = []
        let count = min(query.resultCount, 60)
        for i in 0..<count {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if path.hasSuffix(".app") || path.contains("/Library/") || path.contains("/.") { continue }
            urls.append(URL(fileURLWithPath: path))
            if urls.count == 8 { break }
        }
        results = urls
    }
}
