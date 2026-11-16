import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Drags inside the menu carry the app's path under this private type, never as a file URL,
    /// so dropping a row on Finder or the Desktop can't move the real app.
    static let mac2SevenApp = UTType(exportedAs: "com.csioly.Mac2Seven.app-reference")
    /// A folder from All Programs being dragged.
    static let mac2SevenFolder = UTType(exportedAs: "com.csioly.Mac2Seven.folder-reference")
}

/// Types an app drop target accepts: rows from this menu, or .app files dragged in from Finder.
let appDropTypes: [UTType] = [.mac2SevenApp, .fileURL]

enum DropPayload: Equatable {
    case apps([String])
    case folder(UUID)

    /// The id used in reorder lists: an app path or a folder's UUID string.
    var itemID: String? {
        switch self {
        case .apps(let paths): return paths.first
        case .folder(let id): return id.uuidString
        }
    }
}

/// Keeps only .app bundles from a list of dropped URLs.
func appPaths(_ urls: [URL]) -> [String] {
    urls.filter { $0.isFileURL && $0.pathExtension == "app" }.map(\.path)
}

/// Reads dropped items (apps from this menu or Finder, or one of our folders).
func loadPayload(_ providers: [NSItemProvider], _ done: @escaping (DropPayload) -> Void) {
    let folderID = UTType.mac2SevenFolder.identifier
    if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(folderID) }) {
        _ = provider.loadDataRepresentation(forTypeIdentifier: folderID) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
            DispatchQueue.main.async { done(.folder(id)) }
        }
        return
    }

    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    func add(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }
    for provider in providers {
        if provider.hasItemConformingToTypeIdentifier(UTType.mac2SevenApp.identifier) {
            group.enter()
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.mac2SevenApp.identifier) { data, _ in
                if let data, let path = String(data: data, encoding: .utf8) { add(URL(fileURLWithPath: path)) }
                group.leave()
            }
        } else if provider.canLoadObject(ofClass: NSURL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                if let url = object as? NSURL as URL? { add(url) }
                group.leave()
            }
        }
    }
    group.notify(queue: .main) { done(.apps(appPaths(urls))) }
}

private func privateProvider(_ type: UTType, _ text: String) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
        completion(Data(text.utf8), nil)
        return nil
    }
    return provider
}

/// What follows the cursor while dragging: icon and name, without any hover highlight.
struct DragPreview: View {
    let icon: Image
    let name: String
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 7) {
            icon
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(tint ?? .primary)
                .frame(width: 20, height: 20)
            Text(name)
                .scaledFont(size: 12)
                .foregroundStyle(Color.black.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.92)))
        .environment(\.colorScheme, .light)
    }
}

extension View {
    /// Makes an app row draggable within Mac2Seven only.
    func appDrag(_ item: AppItem, state: MenuState) -> some View {
        onDrag({
            state.beginDrag(.apps([item.path]))
            return privateProvider(.mac2SevenApp, item.path)
        }, preview: {
            DragPreview(icon: Image(nsImage: IconCache.icon(item.path)), name: item.name)
        })
    }

    /// Makes a folder draggable within Mac2Seven only.
    func folderDrag(_ folder: Folder, state: MenuState) -> some View {
        onDrag({
            state.beginDrag(.folder(folder.id))
            return privateProvider(.mac2SevenFolder, folder.id.uuidString)
        }, preview: {
            DragPreview(icon: Image(systemName: "folder.fill"), name: folder.name, tint: Theme.folderTint)
        })
    }

    /// A drop target that accepts apps anywhere in this view.
    func appDrop(isTargeted: Binding<Bool>, state: MenuState, perform: @escaping ([String]) -> Void) -> some View {
        itemDrop(isTargeted: isTargeted, state: state, types: appDropTypes, apps: perform, folder: { _ in })
    }

    /// A drop target that accepts apps and folders anywhere in this view.
    func itemDrop(
        isTargeted: Binding<Bool>,
        state: MenuState,
        types: [UTType] = appDropTypes + [.mac2SevenFolder],
        apps: @escaping ([String]) -> Void,
        folder: @escaping (UUID) -> Void
    ) -> some View {
        onDrop(of: types, isTargeted: isTargeted) { providers in
            state.commitDrag()
            loadPayload(providers) { payload in
                switch payload {
                case .apps(let paths): apps(paths)
                case .folder(let id): folder(id)
                }
            }
            return true
        }
    }

    /// Reorder target for an app row. Apps dragged from the menu move here live as the cursor passes over;
    /// apps dragged in from Finder show a blue line instead.
    /// - Parameters:
    ///   - key: unique among the rows on screen.
    ///   - target: this row's app path; `order` is the list it belongs to.
    func reorderDrop(key: String, target: String, order: [String],
                     perform: @escaping ([String], DropEdge) -> Void) -> some View {
        modifier(ReorderDropModifier(key: key, target: target, order: order, types: appDropTypes) { payload, edge in
            if case .apps(let paths) = payload { perform(paths, edge) }
        })
    }

    /// Drop target for a folder's title row: folders dragged over it move above or below it live,
    /// and apps dropped on it go into the folder (open or closed).
    func folderHeaderDrop(target: UUID, siblings: [UUID], isTargeted: Binding<Bool>, state: MenuState,
                          reorder: @escaping (UUID, DropEdge) -> Void,
                          apps: @escaping ([String]) -> Void) -> some View {
        onDrop(of: appDropTypes + [.mac2SevenFolder], delegate: FolderHeaderDelegate(
            target: target, siblings: siblings, isTargeted: isTargeted, state: state, reorder: reorder, apps: apps
        ))
    }

    /// Hover tracking that goes through the shared menu state, so only one row is ever highlighted.
    func trackHover(_ key: String, state: MenuState) -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active: state.setHover(key, true)
            case .ended: state.setHover(key, false)
            }
        }
    }
}

private struct ReorderDropModifier: ViewModifier {
    let key: String
    let target: String
    let order: [String]
    let types: [UTType]
    let perform: (DropPayload, DropEdge) -> Void
    @EnvironmentObject var state: MenuState
    @State private var height: CGFloat = 0

    private var edge: DropEdge? {
        state.dropLine?.id == key ? state.dropLine?.edge : nil
    }

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { height = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in height = h }
                }
            )
            .overlay(alignment: edge == .after ? .bottom : .top) {
                if let edge {
                    InsertionLine().offset(y: edge == .after ? 1 : -1)
                }
            }
            .onDrop(of: types, delegate: ReorderDelegate(
                key: key, target: target, order: order, types: types,
                state: state, height: height, perform: perform
            ))
    }
}

private struct ReorderDelegate: DropDelegate {
    let key: String
    let target: String
    let order: [String]
    let types: [UTType]
    let state: MenuState
    let height: CGFloat
    let perform: (DropPayload, DropEdge) -> Void

    /// The drag started inside the menu and this row accepts that kind of item.
    private var internalPayload: DropPayload? {
        guard let payload = state.dragPayload else { return nil }
        switch payload {
        case .apps: return types.contains(.mac2SevenApp) ? payload : nil
        case .folder: return types.contains(.mac2SevenFolder) ? payload : nil
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: types)
    }

    /// The drag carries one of our private types, so it came from inside the menu (never show a line for it).
    private func isFromMenu(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.mac2SevenApp, .mac2SevenFolder])
    }

    func dropEntered(info: DropInfo) {
        guard let payload = internalPayload else {
            if !isFromMenu(info) { state.beginDrag(nil) }
            return
        }
        // Moving down the list lands after this row, moving up lands before it, so the list doesn't jitter.
        var edge = DropEdge.before
        if let dragged = payload.itemID,
           let from = order.firstIndex(of: dragged),
           let to = order.firstIndex(of: target),
           from < to {
            edge = .after
        }
        withAnimation(.easeOut(duration: 0.15)) {
            perform(payload, edge)
        }
        state.markLiveMove()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if internalPayload == nil, !isFromMenu(info) {
            // Dragged in from Finder: show where it will land.
            state.beginDrag(nil)
            let line = MenuState.DropLine(id: key, edge: info.location.y < height / 2 ? .before : .after)
            if state.dropLine != line { state.dropLine = line }
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if state.dropLine?.id == key { state.dropLine = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        state.commitDrag()
        if internalPayload != nil || isFromMenu(info) { // already moved into place
            state.dropLine = nil
            return true
        }
        let side = state.dropLine?.id == key ? (state.dropLine?.edge ?? .before) : .before
        state.dropLine = nil
        loadPayload(info.itemProviders(for: types)) { perform($0, side) }
        return true
    }
}

private struct FolderHeaderDelegate: DropDelegate {
    let target: UUID
    let siblings: [UUID]
    @Binding var isTargeted: Bool
    let state: MenuState
    let reorder: (UUID, DropEdge) -> Void
    let apps: ([String]) -> Void

    private var draggedFolder: UUID? {
        if case .folder(let id) = state.dragPayload { return id }
        return nil
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: appDropTypes + [.mac2SevenFolder])
    }

    func dropEntered(info: DropInfo) {
        if let dragged = draggedFolder {
            // Same live reordering as other rows: moving down lands after, moving up lands before.
            var edge = DropEdge.before
            if let from = siblings.firstIndex(of: dragged), let to = siblings.firstIndex(of: target), from < to {
                edge = .after
            }
            withAnimation(.easeOut(duration: 0.15)) { reorder(dragged, edge) }
            state.markLiveMove()
        } else {
            if !info.hasItemsConforming(to: [.mac2SevenApp, .mac2SevenFolder]) { state.beginDrag(nil) }
            isTargeted = true
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        state.commitDrag()
        isTargeted = false
        if draggedFolder != nil { return true } // already moved into place
        loadPayload(info.itemProviders(for: appDropTypes)) { payload in
            if case .apps(let paths) = payload { apps(paths) }
        }
        return true
    }
}

private struct InsertionLine: View {
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .strokeBorder(p.insertionLine, lineWidth: 2)
                .frame(width: 8, height: 8)
            Rectangle()
                .fill(p.insertionLine)
                .frame(height: 2.5)
        }
        .frame(height: 8)
        .allowsHitTesting(false)
    }
}
