import AppKit
import SwiftUI

/// What a hover preview or click shows windows for.
enum PreviewTarget: Equatable {
    case app(String)        // app path: all its windows
    case window(CGWindowID) // one window (labels mode)
}

/// Which element the pointer is over, worked out by the controller from the pointer position.
@MainActor
final class HoverModel: ObservableObject {
    @Published var hoveredID: String?
    @Published var previewCard: CGWindowID?
    @Published var previewClose = false
    /// The app whose button is being dragged to a new place, and where the drop line goes (bar coordinates,
    /// origin top-left).
    @Published var draggingPath: String?
    /// Set when one window's button (window titles mode) is being dragged, rather than the whole app.
    @Published var draggingWindow: CGWindowID?
    @Published var dropLine: CGRect?
}

/// Callbacks from the taskbar view to its controller.
struct TaskbarActions {
    var start: (NSRect) -> Void
    /// Records where a hoverable element is on screen (the controller tracks the pointer itself, because
    /// SwiftUI hover events don't arrive in a panel of a background app).
    /// The UUID identifies the view doing the registering: a view leaving the bar only removes its own
    /// entry, never one a newer copy of the same button has already made.
    var register: (String, PreviewTarget?, NSRect, UUID) -> Void
    var showPreview: (PreviewTarget, NSRect) -> Void
    var hidePreview: () -> Void
    var openSettings: () -> Void
    /// Opens or closes the calendar above the clock (given in screen coordinates).
    var calendar: (NSRect) -> Void
    /// Starts Mac2Seven Snip.
    var snip: () -> Void
    /// A button is being dragged: the app's path, the window when it's one window's button, and the
    /// pointer (screen coordinates).
    var dragMoved: (String, CGWindowID?, NSPoint) -> Void
    /// The drag ended at this point; the controller saves the new order if it's over the bar.
    var dragEnded: (String, CGWindowID?, NSPoint) -> Void
    /// The dragged button went away before the drag ended.
    var dragCancelled: () -> Void
}

struct TaskbarView: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var tracker: WindowTracker
    @Environment(\.colorScheme) private var systemScheme
    /// The bar's frame on screen, used to turn button frames into screen coordinates.
    let barFrame: NSRect
    let actions: TaskbarActions

    static let rowHeight: CGFloat = 48
    static let trayWidth: CGFloat = 150

    private var settings: TaskbarSettings { prefs.data.taskbar }
    private var dark: Bool {
        switch prefs.data.appearance {
        case .system: return systemScheme == .dark
        case .light: return false
        case .dark: return true
        }
    }

    var body: some View {
        let fit = fitted
        HStack(spacing: 0) {
            if settings.alignment == .center { Color.clear.frame(width: Self.trayWidth) }
            TaskbarFlow(rows: settings.rows, rowHeight: Self.rowHeight, centered: settings.alignment == .center) {
                StartButton(barFrame: barFrame, actions: actions)
                ForEach(fit.shown) { button in
                    TaskButtonView(button: button, labelWidth: fit.labelWidth, barFrame: barFrame, actions: actions)
                }
                if !fit.overflow.isEmpty {
                    OverflowButton(items: fit.overflow, barFrame: barFrame, actions: actions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, settings.alignment == .left ? 6 : 0)
            TrayView(barFrame: barFrame, actions: actions, needsAccess: !tracker.hasAccessibility,
                     showSnip: prefs.data.snip.taskbarButton,
                     onDesktop: { tracker.toggleDesktop() },
                     onAccess: { tracker.requestAccessibility(); actions.openSettings() })
                .frame(width: Self.trayWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TaskbarBackground(dark: dark))
        .contextMenu {
            Button("Taskbar Settings…") { actions.openSettings() }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        .overlay(alignment: .topLeading) { DropLine() }
        .environment(\.taskbarAccent, prefs.accentColor)
        .environment(\.textScale, prefs.data.taskbarTextScale)
    }

    // MARK: Fitting buttons into the bar

    static let iconWidth: CGFloat = 42
    static let startWidth: CGFloat = 46
    static let maxLabelWidth: CGFloat = 168
    static let minLabelWidth: CGFloat = 104
    static let spacing: CGFloat = 2

    struct Fit {
        var shown: [TaskButton]
        var overflow: [TaskButton]
        var labelWidth: CGFloat
    }

    /// What fits, Windows-style: labeled buttons first get narrower, then apps with several windows
    /// combine into one button (biggest first), and whatever still doesn't fit goes in the overflow menu.
    private var fitted: Fit {
        let rowWidth = barFrame.width - (settings.alignment == .center ? 2 * Self.trayWidth : Self.trayWidth + 6)
        let rows = settings.rows
        // Optionally drop running apps with no open windows (unless pinned), like Windows does when you
        // close an app's last window. Only when windows can be seen at all, or every app would vanish.
        let apps = settings.hideWindowless && tracker.hasAccessibility
            ? tracker.apps.filter { $0.pinned || !$0.windows.isEmpty }
            : tracker.apps

        func buttons(combining combined: Set<String>) -> [TaskButton] {
            apps.flatMap { app -> [TaskButton] in
                if settings.buttons == .labels, !app.windows.isEmpty, !combined.contains(app.path) {
                    return app.windows.map { TaskButton(app: app, window: $0) }
                }
                // Combined with app names: running apps get a full-width button; pinned-only apps stay icons.
                // Only apps with a window open get a name; a running app with none is a plain icon (with its dot).
                return [TaskButton(app: app, window: nil, appLabel: settings.buttons == .combineLabels && !app.windows.isEmpty)]
            }
        }
        func widths(_ list: [TaskButton], _ label: CGFloat) -> [CGFloat] {
            [Self.startWidth] + list.map { $0.labeled ? label : Self.iconWidth }
        }
        func fitsAll(_ list: [TaskButton], _ label: CGFloat) -> Bool {
            let w = widths(list, label)
            return Self.placed(w, rowWidth: rowWidth, rows: rows) == w.count
        }

        var list = buttons(combining: [])
        var label = Self.maxLabelWidth
        if settings.buttons != .combine {
            while label > Self.minLabelWidth, !fitsAll(list, label) { label -= 4 }
        }
        if settings.buttons == .labels {
            if !fitsAll(list, label) {
                var combined = Set<String>()
                for app in apps.filter({ $0.windows.count > 1 }).sorted(by: { $0.windows.count > $1.windows.count }) {
                    combined.insert(app.path)
                    list = buttons(combining: combined)
                    if fitsAll(list, label) { break }
                }
            }
        }
        if fitsAll(list, label) { return Fit(shown: list, overflow: [], labelWidth: label) }

        // Keep as many as fit alongside the overflow button.
        var count = list.count
        while count > 0 {
            let w = widths(Array(list.prefix(count)), label) + [Self.iconWidth]
            if Self.placed(w, rowWidth: rowWidth, rows: rows) == w.count { break }
            count -= 1
        }
        return Fit(shown: Array(list.prefix(count)), overflow: Array(list.dropFirst(count)), labelWidth: label)
    }

    /// How many items of these widths fit when wrapped onto at most `rows` rows (same rule as TaskbarFlow).
    static func placed(_ widths: [CGFloat], rowWidth: CGFloat, rows: Int) -> Int {
        var row = 1
        var x: CGFloat = 0
        for (i, w) in widths.enumerated() {
            let needed = x == 0 ? w : x + spacing + w
            if needed > rowWidth {
                if row == rows || x == 0 { return i }
                row += 1
                x = w
            } else {
                x = needed
            }
        }
        return widths.count
    }
}

struct TaskButton: Identifiable {
    let app: TaskApp
    let window: TaskWindow?
    /// A combined app button that shows the app's name.
    var appLabel = false
    var labeled: Bool { window != nil || appLabel }
    var id: String { window.map { "w\($0.id)" } ?? app.path }
}

private struct AccentKey: EnvironmentKey { static let defaultValue = Color.accentColor }
extension EnvironmentValues {
    var taskbarAccent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}

// MARK: Background

struct TaskbarBackground: View {
    let dark: Bool

    var body: some View {
        ZStack(alignment: .top) {
            VisualEffect(material: .hudWindow)
            (dark ? Color(white: 0.11).opacity(0.78) : Color(white: 0.95).opacity(0.82))
            Rectangle().fill(dark ? Color.white.opacity(0.10) : Color.black.opacity(0.12)).frame(height: 1)
        }
    }
}

// MARK: Buttons

/// Reports a view's frame in screen coordinates, and registers it with the controller for hover tracking.
private struct ScreenFrameReader: View {
    let barFrame: NSRect
    @Binding var frame: NSRect
    var id: String
    var target: PreviewTarget?
    var actions: TaskbarActions
    @State private var token = UUID()
    /// Set once this view has left the bar, so a late geometry change can't put its stale entry back.
    @State private var gone = false

    var body: some View {
        GeometryReader { geo in
            let g = geo.frame(in: .global)
            Color.clear
                .onAppear { gone = false; update(g) }
                .onChange(of: g) { _, new in update(new) }
                .onDisappear {
                    gone = true
                    actions.register(id, nil, .zero, token)
                }
        }
    }

    private func update(_ g: CGRect) {
        guard !gone else { return }
        frame = convert(g)
        actions.register(id, target, frame, token)
    }

    private func convert(_ g: CGRect) -> NSRect {
        NSRect(x: barFrame.minX + g.minX, y: barFrame.maxY - g.maxY, width: g.width, height: g.height)
    }
}

/// A taskbar button's background. Open apps get a tile with a border, like the Windows taskbar; the app
/// in front gets a stronger one. (`primary` is dark on a light taskbar and light on a dark one, so the tile
/// stands out either way.)
struct ButtonChrome: View {
    let hovering: Bool
    let pressedLook: Bool
    var open = false

    private var fill: Double {
        if pressedLook { return hovering ? 0.16 : 0.13 }
        if open { return hovering ? 0.11 : 0.075 }
        return hovering ? 0.09 : 0
    }

    private var border: Double {
        if pressedLook { return 0.24 }
        if open { return 0.16 }
        return 0
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.primary.opacity(fill))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(border), lineWidth: 1)
            )
    }
}

struct StartButton: View {
    let barFrame: NSRect
    let actions: TaskbarActions
    @EnvironmentObject var hover: HoverModel
    @State private var frame = NSRect.zero
    private var hovering: Bool { hover.hoveredID == "start" }

    var body: some View {
        Button { actions.start(frame) } label: {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
                .frame(width: TaskbarView.startWidth, height: 40)
                .background(ButtonChrome(hovering: hovering, pressedLook: false))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(ScreenFrameReader(barFrame: barFrame, frame: $frame, id: "start", target: nil, actions: actions))
        .help("Start")
    }
}

struct TaskButtonView: View {
    let button: TaskButton
    var labelWidth: CGFloat = TaskbarView.maxLabelWidth
    let barFrame: NSRect
    let actions: TaskbarActions
    @EnvironmentObject var tracker: WindowTracker
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var hover: HoverModel
    @Environment(\.taskbarAccent) private var accent
    @State private var frame = NSRect.zero
    private var hovering: Bool { hover.hoveredID == button.id }

    private var app: TaskApp { button.app }
    private var labeled: Bool { button.labeled }

    private var isActive: Bool {
        guard app.isFrontmost, !app.isHidden else { return false }
        if let window = button.window { return tracker.activeWindow == window.id && !window.minimized }
        if app.windows.isEmpty { return true }
        return app.windows.contains { $0.id == tracker.activeWindow && !$0.minimized }
    }

    private var target: PreviewTarget {
        button.window.map { .window($0.id) } ?? .app(app.path)
    }

    private var hasWindow: Bool { button.window != nil || !app.windows.isEmpty }

    private var isDragged: Bool {
        if let window = button.window, let dragged = hover.draggingWindow { return dragged == window.id }
        return hover.draggingPath == app.path && hover.draggingWindow == nil
    }
    private static let dragThreshold: CGFloat = 5

    var body: some View {
        content
            // One gesture for both: a press that barely moves is a click; anything more drags the button
            // to a new place. (A Button would swallow the drag.)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        guard !NSEvent.modifierFlags.contains(.control) else { return }
                        if hypot(value.translation.width, value.translation.height) > Self.dragThreshold {
                            actions.dragMoved(app.path, button.window?.id, screenPoint(value.location))
                        }
                    }
                    .onEnded { value in
                        // Control-click opens the context menu; it isn't a click on the button too.
                        guard !NSEvent.modifierFlags.contains(.control) else { return }
                        if hypot(value.translation.width, value.translation.height) > Self.dragThreshold {
                            actions.dragEnded(app.path, button.window?.id, screenPoint(value.location))
                        } else {
                            click()
                        }
                    }
            )
            // The button may leave the bar mid-drag (its window closed, it moved to overflow); SwiftUI then never
            // ends the gesture, so tell the controller.
            .onDisappear { if isDragged { actions.dragCancelled() } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { click() }
            .background(ScreenFrameReader(barFrame: barFrame, frame: $frame, id: button.id, target: target, actions: actions))
            .help(labeled ? "" : app.name)
            .contextMenu { menu }
    }

    private func screenPoint(_ p: CGPoint) -> NSPoint {
        NSPoint(x: barFrame.minX + p.x, y: barFrame.maxY - p.y)
    }

    private var content: some View {
            HStack(spacing: 8) {
                Image(nsImage: IconCache.icon(app.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: labeled ? 24 : 28, height: labeled ? 24 : 28)
                if labeled {
                    Text(button.window?.title ?? app.name)
                        .scaledFont(size: 12)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if button.appLabel, app.windows.count > 1 {
                        Text("\(app.windows.count)")
                            .scaledFont(size: 10, weight: .semibold)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.12)))
                    }
                }
            }
            .padding(.horizontal, labeled ? 8 : 6)
            .frame(width: labeled ? labelWidth : TaskbarView.iconWidth, height: 40)
            // Only apps with a window open get a tile. Mac apps keep running with no windows (Finder, Word
            // after closing the last document); those keep their running dot but no tile.
            .background(ButtonChrome(hovering: hovering, pressedLook: isActive && hasWindow, open: hasWindow))
            .overlay(alignment: .bottom) { indicator }
            .opacity(isDragged ? 0.4 : (button.window?.minimized == true ? 0.75 : 1))
            .contentShape(Rectangle())
    }

    @ViewBuilder private var indicator: some View {
        if app.isRunning {
            Capsule()
                .fill(isActive ? accent : Color.primary.opacity(0.45))
                .frame(width: isActive ? (labeled ? 28 : 16) : 6, height: 3)
                .padding(.bottom, 1)
                .animation(.easeOut(duration: 0.15), value: isActive)
        }
    }

    private func click() {
        actions.hidePreview()
        if let window = button.window {
            tracker.toggle(window)
        } else if app.windows.count > 1 {
            actions.showPreview(target, frame)
        } else {
            tracker.toggle(app)
        }
    }

    @ViewBuilder private var menu: some View {
        Button(app.isRunning ? "New \(app.name) Window" : "Open \(app.name)") {
            tracker.launch(app.path)
        }
        Divider()
        if app.pinned {
            Button("Unpin from Taskbar") { prefs.data.taskbar.pinned.removeAll { $0 == app.path } }
        } else {
            Button("Pin to Taskbar") { prefs.data.taskbar.pinned.append(app.path) }
        }
        if let window = button.window {
            Divider()
            Button(window.minimized ? "Restore" : "Minimize") {
                window.minimized ? tracker.focus(window) : tracker.minimize(window)
            }
            Button("Close Window") { tracker.close(window) }
        } else if !app.windows.isEmpty {
            Divider()
            Button(app.windows.count > 1 ? "Close All Windows" : "Close Window") { tracker.closeAll(app) }
        }
        if app.isRunning {
            Button("Quit \(app.name)") { tracker.quit(app) }
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
        }
    }
}

// MARK: Overflow

/// The ⌃ button shown when not everything fits: lists the rest in a menu.
struct OverflowButton: View {
    let items: [TaskButton]
    let barFrame: NSRect
    let actions: TaskbarActions
    @EnvironmentObject var tracker: WindowTracker
    @EnvironmentObject var hover: HoverModel
    @State private var frame = NSRect.zero

    var body: some View {
        Button(action: showMenu) {
            Image(systemName: "chevron.up")
                .scaledFont(size: 13, weight: .semibold)
                .frame(width: TaskbarView.iconWidth, height: 40)
                .background(ButtonChrome(hovering: hover.hoveredID == "overflow", pressedLook: false))
                .overlay(alignment: .topTrailing) {
                    Text("\(items.count)")
                        .scaledFont(size: 9, weight: .bold)
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.18)))
                        .padding(3)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(ScreenFrameReader(barFrame: barFrame, frame: $frame, id: "overflow", target: nil, actions: actions))
        .help("\(items.count) more")
    }

    private func showMenu() {
        actions.hidePreview()
        let menu = NSMenu()
        for item in items {
            let app = item.app
            if let window = item.window {
                menu.addItem(MenuAction.item(window.title, icon: app.path) { tracker.focus(window) })
            } else if app.windows.count > 1 {
                let parent = NSMenuItem(title: "\(app.name) (\(app.windows.count))", action: nil, keyEquivalent: "")
                parent.image = MenuAction.icon(app.path)
                let sub = NSMenu()
                for window in app.windows {
                    sub.addItem(MenuAction.item(window.title + (window.minimized ? "  (minimized)" : ""), icon: nil) {
                        tracker.focus(window)
                    })
                }
                parent.submenu = sub
                menu.addItem(parent)
            } else {
                menu.addItem(MenuAction.item(app.name, icon: app.path) { tracker.toggle(app) })
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: frame.maxY + 4), in: nil)
    }
}

/// An NSMenuItem that runs a closure.
final class MenuAction: NSObject {
    private let run: () -> Void
    private init(_ run: @escaping () -> Void) { self.run = run }
    @objc private func fire() { run() }

    @MainActor
    static func item(_ title: String, icon path: String?, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        item.target = action
        item.representedObject = action // the item keeps its action alive
        item.image = path.map(icon)
        return item
    }

    @MainActor
    static func icon(_ path: String) -> NSImage {
        let image = (IconCache.icon(path).copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

// MARK: Tray

struct TrayView: View {
    let barFrame: NSRect
    let actions: TaskbarActions
    let needsAccess: Bool
    let showSnip: Bool
    let onDesktop: () -> Void
    let onAccess: () -> Void
    @EnvironmentObject var hover: HoverModel
    @State private var snipFrame = NSRect.zero
    @State private var clockFrame = NSRect.zero
    @State private var desktopFrame = NSRect.zero
    @State private var accessFrame = NSRect.zero
    private var clockHover: Bool { hover.hoveredID == "clock" }
    private var desktopHover: Bool { hover.hoveredID == "desktop" }

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if showSnip {
                Button(action: actions.snip) {
                    Image(systemName: "scissors")
                        .scaledFont(size: 15)
                        .frame(width: 32, height: 40)
                        .background(ButtonChrome(hovering: hover.hoveredID == "snip", pressedLook: false))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(ScreenFrameReader(barFrame: barFrame, frame: $snipFrame, id: "snip", target: nil, actions: actions))
                .help("Take a screenshot (Snip)")
            }
            if needsAccess {
                // Without Accessibility the taskbar can't see windows; say so where it matters.
                Button(action: onAccess) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .frame(width: 32, height: 40)
                        .background(ButtonChrome(hovering: hover.hoveredID == "access", pressedLook: false))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(ScreenFrameReader(barFrame: barFrame, frame: $accessFrame, id: "access", target: nil, actions: actions))
                .help("Allow Accessibility so the taskbar can show and manage windows")
            }
            TimelineView(.periodic(from: .now, by: 10)) { context in
                VStack(alignment: .trailing, spacing: 1) {
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                    Text(context.date.formatted(date: .numeric, time: .omitted))
                }
                .scaledFont(size: 12)
                .padding(.horizontal, 8)
                .frame(height: 40)
                .background(ButtonChrome(hovering: clockHover, pressedLook: false))
                .contentShape(Rectangle())
                .background(ScreenFrameReader(barFrame: barFrame, frame: $clockFrame, id: "clock", target: nil, actions: actions))
                .onTapGesture { actions.calendar(clockFrame) }
            }
            // Thin strip at the far edge: Show Desktop.
            Rectangle()
                .fill(Color.primary.opacity(desktopHover ? 0.12 : 0.001))
                .frame(width: 8)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1).padding(.vertical, 10)
                }
                .background(ScreenFrameReader(barFrame: barFrame, frame: $desktopFrame, id: "desktop", target: nil, actions: actions))
                .onTapGesture(perform: onDesktop)
                .help("Show desktop")
        }
    }
}

// MARK: Layout

/// Lays buttons out in rows of equal height, wrapping onto as many rows as allowed, with the whole
/// block centered (or left-aligned) horizontally and centered vertically.
struct TaskbarFlow: Layout {
    var rows: Int
    var rowHeight: CGFloat
    var centered: Bool
    var spacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 800, height: proposal.height ?? rowHeight * CGFloat(rows))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var lines: [[(Int, CGSize)]] = [[]]
        var width: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let needed = (lines[lines.count - 1].isEmpty ? 0 : spacing) + size.width
            if width + needed > bounds.width, !lines[lines.count - 1].isEmpty, lines.count < rows {
                lines.append([])
                width = 0
            }
            width += (lines[lines.count - 1].isEmpty ? 0 : spacing) + size.width
            lines[lines.count - 1].append((i, size))
        }
        let top = bounds.minY + (bounds.height - rowHeight * CGFloat(lines.count)) / 2
        for (row, line) in lines.enumerated() {
            let lineWidth = line.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(line.count - 1, 0))
            var x = centered ? bounds.minX + max((bounds.width - lineWidth) / 2, 0) : bounds.minX
            let midY = top + rowHeight * (CGFloat(row) + 0.5)
            for (i, size) in line {
                // Buttons that don't fit on the last allowed row are parked out of sight.
                let visible = x + size.width <= bounds.maxX + 0.5
                subviews[i].place(at: CGPoint(x: visible ? x : -10_000, y: midY - size.height / 2),
                                  proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }
}

// MARK: Previews

/// Which windows the preview popup shows; set by the controller.
@MainActor
final class PreviewModel: ObservableObject {
    @Published var target: PreviewTarget?
}

struct PreviewView: View {
    @EnvironmentObject var model: PreviewModel
    @EnvironmentObject var tracker: WindowTracker
    @EnvironmentObject var thumbnails: Thumbnails
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var hover: HoverModel
    @Environment(\.colorScheme) private var systemScheme
    var onDone: () -> Void

    static let cardWidth: CGFloat = 200
    static let cardHeight: CGFloat = 150

    static func windows(for target: PreviewTarget?, in apps: [TaskApp]) -> [(TaskApp, TaskWindow)] {
        switch target {
        case .app(let path):
            guard let app = apps.first(where: { $0.path == path }) else { return [] }
            return app.windows.map { (app, $0) }
        case .window(let id):
            for app in apps { if let w = app.windows.first(where: { $0.id == id }) { return [(app, w)] } }
            return []
        case nil:
            return []
        }
    }

    private var dark: Bool {
        switch prefs.data.appearance {
        case .system: return systemScheme == .dark
        case .light: return false
        case .dark: return true
        }
    }

    var body: some View {
        let items = Self.windows(for: model.target, in: tracker.apps)
        HStack(spacing: 6) {
            ForEach(items, id: \.1.id) { app, window in
                PreviewCard(app: app, window: window, image: thumbnails.images[window.id],
                            active: tracker.activeWindow == window.id && app.isFrontmost,
                            hovering: hover.previewCard == window.id,
                            closeHover: hover.previewCard == window.id && hover.previewClose,
                            onPick: { tracker.focus(window); onDone() },
                            onClose: { tracker.close(window) })
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TaskbarBackground(dark: dark))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

struct PreviewCard: View {
    let app: TaskApp
    let window: TaskWindow
    let image: NSImage?
    let active: Bool
    let hovering: Bool
    let closeHover: Bool
    let onPick: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(nsImage: IconCache.icon(app.path)).resizable().frame(width: 16, height: 16)
                Text(window.title).scaledFont(size: 12).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .scaledFont(size: 10, weight: .semibold)
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 4).fill(closeHover ? Color.red.opacity(0.85) : .clear))
                        .foregroundStyle(closeHover ? .white : .primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
            }
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: IconCache.icon(app.path)).resizable().frame(width: 56, height: 56)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(window.minimized ? 0.6 : 1)
        }
        .padding(8)
        .frame(width: PreviewView.cardWidth, height: PreviewView.cardHeight)
        .background(ButtonChrome(hovering: hovering, pressedLook: active))
        .contentShape(Rectangle())
        .onTapGesture(perform: onPick)
    }
}

/// The blue line that shows where a dragged button will land.
private struct DropLine: View {
    @EnvironmentObject var hover: HoverModel
    @Environment(\.taskbarAccent) private var accent

    var body: some View {
        if let line = hover.dropLine {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 3, height: line.height)
                .offset(x: line.minX - 1.5, y: line.minY)
                .allowsHitTesting(false)
        }
    }
}
