import SwiftUI

enum Theme {
    static let highlightFill = Color(red: 0.80, green: 0.91, blue: 1.0)
    static let highlightStroke = Color(red: 0.49, green: 0.71, blue: 0.93)
    static let glassTop = Color(red: 0.12, green: 0.34, blue: 0.48)
    static let glassBottom = Color(red: 0.04, green: 0.12, blue: 0.22)
    static let insertionLine = Color(red: 0.10, green: 0.40, blue: 0.90)
    static let folderTint = Color(red: 0.88, green: 0.68, blue: 0.22)
}

struct StartMenuView: View {
    var body: some View {
        HStack(spacing: 0) {
            LeftColumn()
                .frame(width: 340)
                .environment(\.colorScheme, .light)
            RightColumn()
                .frame(maxWidth: .infinity)
        }
        .padding(8)
        .frame(width: AppDelegate.panelSize.width, height: AppDelegate.panelSize.height)
        .background(GlassBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }
}

struct GlassBackground: View {
    var body: some View {
        ZStack {
            VisualEffect(material: .hudWindow)
            LinearGradient(
                colors: [Theme.glassTop.opacity(0.62), Theme.glassBottom.opacity(0.72)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // Soft sheen across the top edge.
            LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: .center)
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

struct RowHighlight: View {
    let active: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(active ? Theme.highlightFill : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(active ? Theme.highlightStroke : .clear, lineWidth: 1)
            )
    }
}
