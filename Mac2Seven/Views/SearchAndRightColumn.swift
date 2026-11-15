import Collaboration
import SwiftUI

// MARK: Search results

struct SearchResultsView: View {
    let hits: [SearchHit]
    let open: (SearchHit) -> Void
    @EnvironmentObject var state: MenuState

    var body: some View {
        let selected = min(state.selection, max(hits.count - 1, 0))
        let apps = hits.enumerated().filter { if case .app = $0.element { return true } else { return false } }
        let docs = hits.enumerated().filter { if case .file = $0.element { return true } else { return false } }

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if hits.isEmpty {
                        Text("No items match your search.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                    if !apps.isEmpty {
                        sectionHeader("Programs (\(apps.count))")
                        ForEach(apps, id: \.element.id) { pair in
                            row(pair.element, selected: pair.offset == selected).id(pair.offset)
                        }
                    }
                    if !docs.isEmpty {
                        sectionHeader("Files (\(docs.count))")
                        ForEach(docs, id: \.element.id) { pair in
                            row(pair.element, selected: pair.offset == selected).id(pair.offset)
                        }
                    }
                }
                .padding(6)
            }
            .onChange(of: state.selection) { _, s in proxy.scrollTo(s) }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(red: 0.12, green: 0.25, blue: 0.5))
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func row(_ hit: SearchHit, selected: Bool) -> some View {
        switch hit {
        case .app(let item):
            AppRow(item: item, iconSize: 24, selected: selected)
        case .file(let url):
            FileRow(url: url, selected: selected) { open(hit) }
        }
    }
}

struct FileRow: View {
    let url: URL
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: IconCache.icon(url.path))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .lineLimit(1)
                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RowHighlight(active: hover || selected))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .contextMenu {
            Button("Open") { action() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

// MARK: Right column

struct RightColumn: View {
    @EnvironmentObject var state: MenuState
    private let fm = FileManager.default

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Spacer()
                UserPicture()
                Spacer()
            }
            .padding(.top, 6)
            .padding(.bottom, 10)

            PlaceRow(title: NSFullUserName().isEmpty ? NSUserName() : NSFullUserName(),
                     url: fm.homeDirectoryForCurrentUser, bold: true)
            PlaceRow(title: "Documents", url: dir(.documentDirectory))
            PlaceRow(title: "Pictures", url: dir(.picturesDirectory))
            PlaceRow(title: "Music", url: dir(.musicDirectory))
            PlaceRow(title: "Downloads", url: dir(.downloadsDirectory))
            separator
            PlaceRow(title: "Computer", url: URL(fileURLWithPath: "/"))
            PlaceRow(title: "Applications", url: URL(fileURLWithPath: "/Applications"))
            separator
            PlaceRow(title: "System Settings", url: URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            PlaceRow(title: "Activity Monitor", url: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))

            Spacer()

            HStack {
                Spacer()
                PowerButton()
            }
            .padding(.bottom, 4)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
    }

    private var separator: some View {
        Rectangle()
            .fill(LinearGradient(colors: [.clear, .white.opacity(0.3), .clear], startPoint: .leading, endPoint: .trailing))
            .frame(height: 1)
            .padding(.vertical, 6)
    }

    private func dir(_ d: FileManager.SearchPathDirectory) -> URL {
        fm.urls(for: d, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser
    }
}

struct UserPicture: View {
    @EnvironmentObject var state: MenuState
    private static let userImage: NSImage? = CBIdentity(name: NSUserName(), authority: .default())?.image

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.15)], startPoint: .top, endPoint: .bottom))
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            Group {
                if let path = state.hoverIconPath {
                    Image(nsImage: IconCache.icon(path)).resizable().padding(4)
                } else if let image = Self.userImage {
                    Image(nsImage: image).resizable()
                } else {
                    Image(systemName: "person.crop.square.fill").resizable().foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .animation(.easeOut(duration: 0.12), value: state.hoverIconPath)
    }
}

struct PlaceRow: View {
    let title: String
    let url: URL
    var bold = false
    @EnvironmentObject var state: MenuState
    @State private var hover = false

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: bold ? .semibold : .regular))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(hover ? Color.white.opacity(0.16) : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(hover ? Color.white.opacity(0.35) : .clear)
                    )
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hover = inside
                state.hoverIconPath = inside ? url.path : nil
            }
            .onTapGesture {
                NSWorkspace.shared.open(url)
                state.close()
            }
    }
}

struct PowerButton: View {
    @EnvironmentObject var state: MenuState

    var body: some View {
        HStack(spacing: 0) {
            Button {
                perform(.shutDown)
            } label: {
                Text("Shut down")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 18)

            Menu {
                Button("Log Out") { perform(.logOut) }
                Button("Lock") { perform(.lock) }
                Divider()
                Button("Restart") { perform(.restart) }
                Button("Sleep") { perform(.sleep) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 8)
        }
        .foregroundStyle(.white)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35))
        )
    }

    private func perform(_ action: PowerAction) {
        state.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Power.run(action) }
    }
}
