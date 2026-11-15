import SwiftUI

struct LeftColumn: View {
    @EnvironmentObject var state: MenuState
    @EnvironmentObject var catalog: AppCatalog
    @EnvironmentObject var library: Library
    @EnvironmentObject var files: FileSearch
    @EnvironmentObject var prefs: Preferences
    @Environment(\.palette) private var p
    @FocusState private var searchFocused: Bool

    /// Some newly installed (and not hidden) app is waiting in All Programs.
    private var hasNewApps: Bool {
        guard !DemoMode.isOn else { return false } // sample screenshots shouldn't flag every app as new
        return catalog.apps.contains { library.isNew($0.path) && !library.isHidden($0, autoHide: prefs.data.autoHideHelpers) }
    }

    private var hits: [SearchHit] {
        SearchHit.compute(query: state.query, apps: catalog.apps, files: files.results)
    }

    var body: some View {
        VStack(spacing: 8) {
            // Dropping down from the menu bar, search and All Programs sit at the top; rising from the
            // taskbar's Start button, they sit at the bottom like the Windows menu.
            if !state.fromBottom { searchField }

            VStack(spacing: 0) {
                if state.query.isEmpty && !state.fromBottom {
                    allProgramsButton
                    Divider()
                }
                Group {
                    if !state.query.isEmpty {
                        SearchResultsView(hits: hits, open: open)
                    } else if state.showingAll {
                        AllProgramsView()
                    } else {
                        HomeListView()
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                if state.query.isEmpty && state.fromBottom {
                    Divider()
                    allProgramsButton
                }
            }
            .background(
                RoundedRectangle(cornerRadius: p.cardCorner, style: .continuous)
                    .fill(p.cardFill)
            )
            .clipShape(RoundedRectangle(cornerRadius: p.cardCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: p.cardCorner, style: .continuous)
                    .strokeBorder(p.cardStroke, lineWidth: 1)
            )

            if state.fromBottom { searchField }
        }
        .onChange(of: state.query) { _, q in
            state.selection = 0
            files.search(q)
        }
        .onChange(of: hits.count) { _, n in state.hitCount = n }
        .onChange(of: state.openToken) { _, _ in focusSearch() }
        .onAppear { focusSearch() }
    }

    private var allProgramsButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { state.showingAll.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: state.showingAll ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(p.arrowTint)
                Text(state.showingAll ? "Back" : "All Programs")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(p.text)
                if !state.showingAll && hasNewApps {
                    NewBadge()
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .padding(4)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            TextField("Search programs and files", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit {
                    let list = hits
                    guard !list.isEmpty else { return }
                    open(list[min(state.selection, list.count - 1)])
                }
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: p.searchCorner, style: .continuous).fill(p.searchFill))
        .overlay(
            RoundedRectangle(cornerRadius: p.searchCorner, style: .continuous)
                .strokeBorder(p.searchStroke, lineWidth: 1)
        )
        .padding(.horizontal, 6)
        .padding(state.fromBottom ? .bottom : .top, 2)
    }

    private func focusSearch() {
        guard !DemoMode.isOn else { return } // no blinking cursor in screenshots
        DispatchQueue.main.async { searchFocused = true }
    }

    private func open(_ hit: SearchHit) {
        switch hit {
        case .app(let app): library.launch(app.path)
        case .file(let url): NSWorkspace.shared.open(url)
        }
        state.close()
    }
}

struct HoverButtonStyle: ButtonStyle {
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RowHighlight(active: hover || configuration.isPressed))
            .onHover { hover = $0 }
    }
}

// MARK: Pinned + frequently used

struct HomeListView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var catalog: AppCatalog
    @EnvironmentObject var state: MenuState
    @EnvironmentObject var prefs: Preferences
    @State private var dropTarget = false

    var body: some View {
        let pinned = library.data.pinned.compactMap { catalog.item(for: $0) }
        let showFrequent = prefs.data.frequentCount > 0
        let autoHide = prefs.data.autoHideHelpers
        let frequent = showFrequent
            ? library.frequent(limit: prefs.data.frequentCount, excluding: { path in
                catalog.item(for: path).map { library.isHidden($0, autoHide: autoHide) } ?? false
              }).compactMap { catalog.item(for: $0) }
            : []

        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(pinned) { item in
                    AppRow(item: item, iconSize: 32, bold: true)
                        .reorderDrop(key: "pin:" + item.path, target: item.path, order: library.data.pinned) { paths, edge in
                            library.placePins(paths, relativeTo: item.path, edge: edge)
                        }
                }
                if !pinned.isEmpty && showFrequent {
                    Divider().padding(.vertical, 6).padding(.horizontal, 6)
                }
                if !showFrequent {
                    EmptyView()
                } else if frequent.isEmpty {
                    Text("Apps you open will show up here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(10)
                } else {
                    ForEach(frequent) { item in
                        AppRow(item: item, iconSize: 32)
                    }
                }
            }
            .padding(6)
            .background(ScrollViewHook(scroller: state.autoScroller))
        }
        // Dropping anywhere else in the list pins the app at the end.
        .appDrop(isTargeted: $dropTarget, state: state) { paths in
            library.placePins(paths, relativeTo: nil, edge: .after)
        }
    }
}

// MARK: App row

struct AppRow: View {
    let item: AppItem
    var iconSize: CGFloat = 32
    var bold = false
    var selected = false
    var indent: CGFloat = 0

    @EnvironmentObject var library: Library
    @EnvironmentObject var state: MenuState
    @Environment(\.palette) private var p

    private var hoverKey: String { "app:" + item.path }
    private var highlighted: Bool { selected || (state.hoveredID == hoverKey && !state.isDragging) }

    var body: some View {
        HStack(spacing: iconSize > 20 ? 10 : 7) {
            Image(nsImage: IconCache.icon(item.path))
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
            Text(item.name)
                .font(.system(size: iconSize > 20 ? 13 : 12, weight: bold ? .semibold : .regular))
                .foregroundStyle(p.text)
                .lineLimit(1)
            if library.isNew(item.path) {
                NewBadge()
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 6 + indent)
        .padding(.trailing, 6)
        .padding(.vertical, iconSize > 20 ? 3 : 2)
        .background(RowHighlight(active: highlighted))
        .contentShape(Rectangle())
        .trackHover(hoverKey, state: state)
        .onChange(of: state.hoveredID == hoverKey) { _, isHovered in
            if isHovered {
                state.hoverIconPath = item.path
            } else if state.hoverIconPath == item.path {
                state.hoverIconPath = nil
            }
        }
        .onTapGesture {
            library.launch(item.path)
            state.close()
        }
        // The app being dragged shows faded in the spot it will land.
        .opacity(state.dragPayload == .apps([item.path]) ? 0.35 : 1)
        .appDrag(item, state: state)
        .contextMenu { AppContextMenu(path: item.path) }
    }
}

/// Small "New" tag for recently installed apps.
struct NewBadge: View {
    @Environment(\.palette) private var p

    var body: some View {
        Text("New")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(p.accent))
    }
}

struct AppContextMenu: View {
    let path: String
    @EnvironmentObject var library: Library
    @EnvironmentObject var state: MenuState
    @EnvironmentObject var catalog: AppCatalog
    @EnvironmentObject var prefs: Preferences

    private var isHidden: Bool {
        catalog.item(for: path).map { library.isHidden($0, autoHide: prefs.data.autoHideHelpers) } ?? false
    }

    var body: some View {
        Button("Open") {
            library.launch(path)
            state.close()
        }
        Divider()
        if library.isPinned(path) {
            Button("Unpin from Start Menu") { library.unpin(path) }
        } else {
            Button("Pin to Start Menu") { library.pin(path) }
        }
        if !library.isPinned(path), library.data.usage[path] != nil {
            Button("Remove from This List") { library.forget(path) }
        }
        Menu("Move to Folder") {
            ForEach(library.flatFolders()) { entry in
                Button(String(repeating: "    ", count: entry.depth) + entry.folder.name) {
                    library.move(path, to: entry.folder.id)
                }
            }
            Divider()
            Button("New Folder…") {
                let id = library.addFolder(parent: nil, name: "New Folder")
                library.move(path, to: id)
                state.showingAll = true
            }
        }
        if library.folderContaining(path) != nil {
            Button("Remove from Folder") { library.move(path, to: nil) }
        }
        if isHidden {
            Button("Unhide") { library.unhide(path) }
        } else {
            Button("Hide") { library.hide(path) }
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            state.close()
        }
    }
}
