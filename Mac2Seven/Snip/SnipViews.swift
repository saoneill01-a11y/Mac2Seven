import SwiftUI

/// The bar at the bottom of the screen: capture modes, timer, options, Capture and Cancel.
struct SnipToolbar: View {
    let controller: SnipController
    @EnvironmentObject var model: SnipModel
    @EnvironmentObject var prefs: Preferences

    static let width: CGFloat = 620
    static let height: CGFloat = 92

    private var hint: String {
        switch model.mode {
        case .rectangle:
            return model.hasSelection
                ? "Drag inside to move it or drag its edges to resize, then press Capture or Return."
                : "Drag to select an area."
        case .window: return "Click a window to capture it."
        case .fullScreen: return "Click a display, or press Capture for the one the pointer is on."
        case .freeform:
            return model.hasSelection
                ? "Drag the shape to move it, or draw a new one. Then press Capture or Return."
                : "Draw a shape around what you want to capture."
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(SnipMode.allCases) { mode in
                    ToolButton(title: mode.title, symbol: mode.symbol, selected: model.mode == mode) { model.mode = mode }
                }
                divider
                Menu {
                    Picker("Timer", selection: $model.delay) {
                        Text("No delay").tag(0)
                        Text("3 seconds").tag(3)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                    }
                    .pickerStyle(.inline)
                } label: {
                    ToolLabel(title: model.delay == 0 ? "No delay" : "\(model.delay) sec", symbol: "timer", selected: false)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                Menu {
                    Section("Save to") {
                        Toggle(folderName, isOn: $prefs.data.snip.autoSave)
                        Button("Choose Folder…") { controller.openSettings() }
                    }
                    Section("After capture") {
                        Toggle("Copy to clipboard", isOn: $prefs.data.snip.copyToClipboard)
                        Toggle("Open in Preview", isOn: $prefs.data.snip.openInPreview)
                        Toggle("Show thumbnail", isOn: $prefs.data.snip.showThumbnail)
                    }
                    Section("Include") {
                        Toggle("Mouse pointer", isOn: $prefs.data.snip.showPointer)
                        Toggle("Window shadow", isOn: $prefs.data.snip.windowShadow)
                    }
                } label: {
                    ToolLabel(title: "Options", symbol: "slider.horizontal.3", selected: false)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                divider
                Button { controller.captureNow() } label: {
                    Text("Capture")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(prefs.accentColor))
                }
                .buttonStyle(.plain)
                Button { controller.cancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Cancel (Esc)")
            }
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: Self.width, height: Self.height)
        .background(
            ZStack {
                VisualEffect(material: .hudWindow)
                Color(white: 0.13).opacity(0.85)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var folderName: String {
        let url = URL(fileURLWithPath: prefs.data.snip.saveFolder)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let parent = url.deletingLastPathComponent()
        let parentName = parent.path == home ? "Home" : parent.lastPathComponent
        return "\(parentName) › \(url.lastPathComponent)"
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 34).padding(.horizontal, 4)
    }
}

private struct ToolLabel: View {
    let title: String
    let symbol: String
    let selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 17))
            Text(title).font(.system(size: 10.5))
        }
        .frame(minWidth: 58, minHeight: 44)
        .padding(.horizontal, 2)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.35) : .clear))
        .contentShape(Rectangle())
    }
}

private struct ToolButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { ToolLabel(title: title, symbol: symbol, selected: selected) }
            .buttonStyle(.plain)
    }
}

/// The big number shown while the timer counts down.
struct SnipCountdown: View {
    @EnvironmentObject var model: SnipModel

    var body: some View {
        Text("\(model.countdown ?? 0)")
            .font(.system(size: 64, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 140, height: 140)
            .background(ZStack { VisualEffect(material: .hudWindow); Color.black.opacity(0.45) })
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// A small preview of the capture in the corner; click it to show the file in Finder.
struct SnipThumbnail: View {
    let image: NSImage
    let onClick: () -> Void

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.6), lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture(perform: onClick)
            .help("Show in Finder")
    }
}
