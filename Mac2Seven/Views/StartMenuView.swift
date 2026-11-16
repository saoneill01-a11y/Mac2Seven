import SwiftUI

/// Fixed colors that don't change with the theme.
enum Theme {
    static let folderTint = Color(red: 0.88, green: 0.68, blue: 0.22)
}

/// Every color and shape the menu draws with, worked out from the theme, light/dark and accent color.
struct Palette {
    var style: ThemeStyle
    var dark: Bool
    var accent: Color

    private var glass: Bool { style == .glass }

    // Shapes
    var outerCorner: CGFloat { glass ? 14 : 6 }
    var cardCorner: CGFloat { glass ? 8 : 3 }
    var rowCorner: CGFloat { glass ? 4 : 2 }
    var searchCorner: CGFloat { glass ? 6 : 2 }

    // Panel background
    var useBlur: Bool { glass }
    var flatBackground: Color { dark ? Color(white: 0.11) : Color(white: 0.90) }
    var glassTop: Color { Color(red: 0.12, green: 0.34, blue: 0.48) }
    var glassBottom: Color { Color(red: 0.04, green: 0.12, blue: 0.22) }
    var outerStroke: Color { glass ? .white.opacity(0.28) : (dark ? .white.opacity(0.10) : .black.opacity(0.15)) }

    // Left column
    var leftScheme: ColorScheme { dark ? .dark : .light }
    var cardFill: Color {
        if glass { return dark ? Color(white: 0.12).opacity(0.94) : Color.white.opacity(0.96) }
        return dark ? Color(white: 0.17) : .white
    }
    var cardStroke: Color {
        if glass { return dark ? .white.opacity(0.12) : .black.opacity(0.25) }
        return dark ? .white.opacity(0.05) : .black.opacity(0.06)
    }
    var text: Color { dark ? .white.opacity(0.92) : .black.opacity(0.85) }
    var sectionHeader: Color { dark ? accent.opacity(0.95) : accent }
    var highlightFill: Color { accent.opacity(glass ? (dark ? 0.32 : 0.16) : (dark ? 0.45 : 0.22)) }
    var highlightStroke: Color { glass ? accent.opacity(dark ? 0.75 : 0.5) : .clear }
    var insertionLine: Color { accent }
    var folderOutline: Color { accent.opacity(0.6) }
    var searchFill: Color { dark ? Color(white: 0.20) : .white }
    var searchStroke: Color {
        if glass { return dark ? .white.opacity(0.15) : .black.opacity(0.3) }
        return dark ? .white.opacity(0.08) : .black.opacity(0.15)
    }
    var arrowTint: Color {
        if glass { return dark ? Color(red: 0.45, green: 0.8, blue: 0.45) : Color(red: 0.2, green: 0.45, blue: 0.2) }
        return accent
    }

    // Right column (always dark on glass; follows light/dark on flat)
    var rightScheme: ColorScheme { glass || dark ? .dark : .light }
    private var rightDark: Bool { rightScheme == .dark }
    var rightText: Color { rightDark ? .white : .black.opacity(0.85) }
    var rightTextShadow: Color { glass ? .black.opacity(0.5) : .clear }
    var rightHoverFill: Color { glass ? .white.opacity(0.16) : (rightDark ? .white.opacity(0.10) : .black.opacity(0.07)) }
    var rightHoverStroke: Color { glass ? .white.opacity(0.35) : .clear }
    var rightSeparator: Color { rightDark ? .white.opacity(glass ? 0.3 : 0.12) : .black.opacity(0.12) }
    var pictureFrame: [Color] {
        glass ? [.white.opacity(0.55), .white.opacity(0.15)]
              : (rightDark ? [.white.opacity(0.10), .white.opacity(0.10)] : [.black.opacity(0.06), .black.opacity(0.06)])
    }
    var buttonFill: [Color] {
        glass ? [.white.opacity(0.22), .white.opacity(0.06)]
              : (rightDark ? [.white.opacity(0.10), .white.opacity(0.10)] : [.black.opacity(0.07), .black.opacity(0.07)])
    }
    var buttonStroke: Color { glass ? .white.opacity(0.35) : .clear }

    @MainActor
    static func make(_ prefs: Preferences, systemDark: Bool) -> Palette {
        let dark: Bool
        switch prefs.data.appearance {
        case .system: dark = systemDark
        case .light: dark = false
        case .dark: dark = true
        }
        return Palette(style: prefs.data.theme, dark: dark, accent: prefs.accentColor)
    }
}

private struct TextScaleKey: EnvironmentKey { static let defaultValue: Double = 1 }

extension EnvironmentValues {
    /// The Text size setting, applied by `scaledFont`.
    var textScale: Double {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

/// A system font whose size follows the Text size setting.
private struct ScaledFont: ViewModifier {
    @Environment(\.textScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: (size * scale).rounded(), weight: weight, design: design))
    }
}

extension View {
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(style: .glass, dark: false, accent: .blue)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

struct StartMenuView: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var state: MenuState
    /// The system's light/dark setting (nothing above this view overrides it).
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let p = Palette.make(prefs, systemDark: systemScheme == .dark)

        GeometryReader { geo in
            HStack(spacing: 0) {
                // The left column keeps its share of the width as the menu is resized (340 of 580).
                LeftColumn()
                    .frame(width: max(300, (geo.size.width - 16) * 0.6))
                    .environment(\.colorScheme, p.leftScheme)
                RightColumn()
                    .frame(maxWidth: .infinity)
                    .environment(\.colorScheme, p.rightScheme)
            }
            .padding(8)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .overlay(alignment: state.fromBottom ? .topTrailing : .bottomTrailing) {
            ResizeGrip(fromBottom: state.fromBottom, color: p.rightText.opacity(0.55))
        }
        .background(PanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: p.outerCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: p.outerCorner, style: .continuous)
                .strokeBorder(p.outerStroke, lineWidth: 1)
        )
        .environment(\.palette, p)
        .environment(\.textScale, prefs.data.textScale)
    }
}

struct PanelBackground: View {
    @Environment(\.palette) private var p

    var body: some View {
        if p.useBlur {
            ZStack {
                VisualEffect(material: .hudWindow)
                LinearGradient(
                    colors: [p.glassTop.opacity(0.62), p.glassBottom.opacity(0.72)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                // Soft sheen across the top edge.
                LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: .center)
            }
        } else {
            p.flatBackground
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
    @Environment(\.palette) private var p

    var body: some View {
        RoundedRectangle(cornerRadius: p.rowCorner, style: .continuous)
            .fill(active ? p.highlightFill : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: p.rowCorner, style: .continuous)
                    .strokeBorder(active ? p.highlightStroke : .clear, lineWidth: 1)
            )
    }
}

/// The corner grip that resizes the menu. Double-click it to go back to the normal size.
struct ResizeGrip: View {
    let fromBottom: Bool
    let color: Color
    @EnvironmentObject var state: MenuState
    /// Where the current drag started; a different start means a new drag (even if the last one was
    /// cancelled and never ended).
    @State private var dragStart: CGPoint?
    @State private var cursorPushed = false

    var body: some View {
        // Three short diagonal lines, slanting toward the corner they sit in.
        Canvas { ctx, size in
            for i in 0..<3 {
                let inset = CGFloat(i) * 4 + 3
                var line = Path()
                if fromBottom {
                    line.move(to: CGPoint(x: inset, y: 1))
                    line.addLine(to: CGPoint(x: size.width - 1, y: size.height - inset))
                } else {
                    line.move(to: CGPoint(x: inset, y: size.height - 1))
                    line.addLine(to: CGPoint(x: size.width - 1, y: inset))
                }
                ctx.stroke(line, with: .color(color), lineWidth: 1.2)
            }
        }
        .frame(width: 14, height: 14)
        .padding(4)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside && !cursorPushed {
                resizeCursor.push()
                cursorPushed = true
            } else if !inside && cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .onDisappear {
            // The menu can close with the pointer still on the grip.
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .onTapGesture(count: 2) { state.resizeHandler(.reset) }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart != value.startLocation {
                        dragStart = value.startLocation
                        state.resizeHandler(.began(value.translation))
                    }
                    state.resizeHandler(.changed)
                }
                .onEnded { _ in
                    dragStart = nil
                    state.resizeHandler(.ended)
                }
        )
        .help("Drag to resize. Double-click for the normal size.")
    }

    private var resizeCursor: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: fromBottom ? .topRight : .bottomRight, directions: .all)
        }
        return NSCursor.crosshair
    }
}
