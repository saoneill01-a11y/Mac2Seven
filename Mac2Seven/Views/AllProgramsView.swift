import SwiftUI

struct AllProgramsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var catalog: AppCatalog
    @EnvironmentObject var state: MenuState
    @State private var expanded: Set<UUID> = []
    @State private var editing: UUID?
    @State private var topDropTarget = false

    var body: some View {
        let loose = library.looseApps(from: catalog.apps)
        let looseOrder = loose.map(\.path)

        VStack(spacing: 0) {
            HStack {
                Text("All Programs")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    editing = library.addFolder(parent: nil)
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(library.data.folders) { folder in
                        FolderTree(folder: folder, siblings: library.data.folders.map(\.id), depth: 0,
                                   expanded: $expanded, editing: $editing)
                    }
                    ForEach(loose) { item in
                        AppRow(item: item, iconSize: 16, indent: 17)
                            .reorderDrop(key: "top:" + item.path, target: item.path, order: looseOrder) { paths, edge in
                                library.placeAtTop(paths, relativeTo: item.path, edge: edge, current: looseOrder)
                            }
                    }
                }
                .padding(6)
                .background(ScrollViewHook(scroller: state.autoScroller))
            }
            // Dropping onto empty space takes an app (or folder) back out to the top level.
            .itemDrop(isTargeted: $topDropTarget, state: state) { paths in
                library.move(paths, to: nil)
            } folder: { id in
                library.nestFolder(id, into: nil)
            }
        }
    }
}

struct FolderTree: View {
    let folder: Folder
    /// The folders at this folder's level, in order (used for live reordering).
    let siblings: [UUID]
    let depth: Int
    @Binding var expanded: Set<UUID>
    @Binding var editing: UUID?

    @EnvironmentObject var library: Library
    @EnvironmentObject var catalog: AppCatalog
    @EnvironmentObject var state: MenuState
    @Environment(\.palette) private var p
    @State private var dropTarget = false
    /// An app is being dragged over this folder's title row.
    @State private var headerTarget = false
    private var anyTarget: Bool { dropTarget || headerTarget }
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    private var isOpen: Bool { expanded.contains(folder.id) }
    private var isEditing: Bool { editing == folder.id }
    private var childIndent: CGFloat { CGFloat(depth + 1) * 16 + 17 }
    private var headerKey: String { "folder:" + folder.id.uuidString }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            if isOpen {
                ForEach(folder.children) { child in
                    FolderTree(folder: child, siblings: folder.children.map(\.id), depth: depth + 1,
                               expanded: $expanded, editing: $editing)
                }
                ForEach(folder.apps, id: \.self) { path in
                    if let item = catalog.item(for: path) {
                        AppRow(item: item, iconSize: 16, indent: childIndent)
                            .reorderDrop(key: "in:\(folder.id.uuidString):" + path, target: path, order: folder.apps) { paths, edge in
                                library.move(paths, to: folder.id, relativeTo: path, edge: edge)
                            }
                    }
                }
                if folder.apps.isEmpty && folder.children.isEmpty {
                    Text("Empty. Drag apps here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, childIndent + 6)
                        .padding(.vertical, 2)
                }
            }
        }
        .padding(.bottom, isOpen ? 3 : 0)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(anyTarget ? p.folderOutline : .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        // The whole folder (its title and, when open, everything inside) accepts apps,
        // and folders dropped into it become subfolders.
        .itemDrop(isTargeted: $dropTarget, state: state) { paths in
            library.move(paths, to: folder.id)
            expanded.insert(folder.id)
        } folder: { id in
            library.nestFolder(id, into: folder.id)
            expanded.insert(folder.id)
        }
        // Hovering a closed folder during a drag springs it open.
        .onChange(of: anyTarget) { _, targeted in
            guard targeted, !isOpen else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                if anyTarget { _ = withAnimation(.easeOut(duration: 0.12)) { expanded.insert(folder.id) } }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Image(systemName: isOpen ? "folder.fill" : "folder")
                .foregroundStyle(Theme.folderTint)
                .frame(width: 16)
            if isEditing {
                TextField("Folder name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .onAppear {
                        draftName = folder.name
                        DispatchQueue.main.async { nameFocused = true }
                    }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(folder.name)
                    .font(.system(size: 12))
                    .foregroundStyle(p.text)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 6 + CGFloat(depth) * 16)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(RowHighlight(active: state.hoveredID == headerKey && !state.isDragging))
        .contentShape(Rectangle())
        .trackHover(headerKey, state: state)
        .onTapGesture {
            guard !isEditing else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                if isOpen { expanded.remove(folder.id) } else { expanded.insert(folder.id) }
            }
        }
        // The folder being dragged shows faded in the spot it will land.
        .opacity(state.dragPayload == .folder(folder.id) ? 0.35 : 1)
        .folderDrag(folder, state: state)
        // Dragging a folder over another folder's title moves it above or below that folder.
        .folderHeaderDrop(target: folder.id, siblings: siblings, isTargeted: $headerTarget, state: state) { id, edge in
            library.placeFolder(id, relativeTo: folder.id, edge: edge)
        } apps: { paths in
            library.move(paths, to: folder.id)
        }
        .contextMenu {
            Button("Rename") { editing = folder.id }
            Button("New Subfolder") {
                let id = library.addFolder(parent: folder.id)
                expanded.insert(folder.id)
                editing = id
            }
            Divider()
            Button("Delete Folder") { library.deleteFolder(folder.id) }
        }
    }

    private func commitRename() {
        guard isEditing else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { library.renameFolder(folder.id, to: name) }
        editing = nil
    }
}
