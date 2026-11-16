import Collaboration
import SwiftUI

// MARK: Search results

struct SearchResultsView: View {
    let hits: [SearchHit]
    let open: (SearchHit) -> Void
    @EnvironmentObject var state: MenuState
    @Environment(\.palette) private var p

    var body: some View {
        let selected = min(state.selection, max(hits.count - 1, 0))
        let apps = hits.enumerated().filter { if case .app = $0.element { return true } else { return false } }
        let docs = hits.enumerated().filter { if case .file = $0.element { return true } else { return false } }

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if hits.isEmpty {
                        Text("No items match your search.")
                            .scaledFont(size: 12)
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
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(p.sectionHeader)
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
    @Environment(\.palette) private var p
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: IconCache.icon(url.path))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(url.lastPathComponent)
                    .scaledFont(size: 12)
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .scaledFont(size: 10)
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
    @EnvironmentObject var prefs: Preferences
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Spacer()
                UserPicture()
                Spacer()
            }
            .padding(.top, 6)
            .padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(prefs.data.places) { place in
                        if place.isSeparator {
                            Rectangle()
                                .fill(LinearGradient(colors: [.clear, p.rightSeparator, .clear],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(height: 1)
                                .padding(.vertical, 6)
                        } else {
                            PlaceRow(place: place)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                PowerButton()
            }
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
    }
}

struct UserPicture: View {
    @EnvironmentObject var state: MenuState
    @Environment(\.palette) private var p
    private static let userImage: NSImage? = CBIdentity(name: NSUserName(), authority: .default())?.image

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: p.cardCorner + 2, style: .continuous)
                .fill(LinearGradient(colors: p.pictureFrame, startPoint: .top, endPoint: .bottom))
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(p.useBlur ? 0.35 : 0), radius: 3, y: 1)
            Group {
                if let path = state.hoverIconPath {
                    Image(nsImage: IconCache.icon(path)).resizable().padding(4)
                } else if DemoMode.isOn {
                    #if DEBUG
                    DemoAvatar()
                    #endif
                } else if let image = Self.userImage {
                    Image(nsImage: image).resizable()
                } else {
                    Image(systemName: "person.crop.square.fill").resizable().foregroundStyle(p.rightText.opacity(0.85))
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: max(p.cardCorner - 2, 1), style: .continuous))
        }
        .animation(.easeOut(duration: 0.12), value: state.hoverIconPath)
    }
}

struct PlaceRow: View {
    let place: Place
    @EnvironmentObject var state: MenuState
    @Environment(\.palette) private var p
    @State private var hover = false

    var body: some View {
        Text(place.title)
            .scaledFont(size: 13, weight: place.bold ? .semibold : .regular)
            .foregroundStyle(p.rightText)
            .shadow(color: p.rightTextShadow, radius: 1, y: 1)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: p.rowCorner, style: .continuous)
                    .fill(hover ? p.rightHoverFill : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: p.rowCorner, style: .continuous)
                            .strokeBorder(hover ? p.rightHoverStroke : .clear)
                    )
            )
            .contentShape(Rectangle())
            .onHover { inside in
                guard !DemoMode.isOn else { return }
                hover = inside
                state.hoverIconPath = inside ? place.path : nil
            }
            .onTapGesture {
                NSWorkspace.shared.open(place.url)
                state.close()
            }
            .help(place.path)
    }
}

struct PowerButton: View {
    @EnvironmentObject var state: MenuState
    @EnvironmentObject var prefs: Preferences
    @Environment(\.palette) private var p

    var body: some View {
        let main = prefs.data.powerAction

        HStack(spacing: 0) {
            Button {
                perform(main)
            } label: {
                Text(main.title)
                    .scaledFont(size: 12, weight: .medium)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle().fill(p.rightSeparator).frame(width: 1, height: 18)

            Menu {
                ForEach(PowerAction.allCases.filter { $0 != main }) { action in
                    Button(action.title) { perform(action) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .scaledFont(size: 10, weight: .bold)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 8)
        }
        .foregroundStyle(p.rightText)
        .background(
            RoundedRectangle(cornerRadius: p.rowCorner, style: .continuous)
                .fill(LinearGradient(colors: p.buttonFill, startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: p.rowCorner, style: .continuous)
                .strokeBorder(p.buttonStroke)
        )
    }

    private func perform(_ action: PowerAction) {
        state.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Power.run(action) }
    }
}
