import AppKit
import Combine
import SwiftUI

/// Borderless bar along the bottom of a screen. It never takes focus, so clicking it doesn't steal
/// the keyboard from the app you're using.
final class TaskbarPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        // In demo mode it sits above the screenshot backdrop (which covers the real desktop).
        level = DemoMode.isOn ? .popUpMenu : .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that takes the first click even while another app is active.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        // The window decides the size. Otherwise SwiftUI's content size (e.g. the width of three preview
        // cards) can hold the view wider than the window after it shrinks.
        sizingOptions = []
        autoresizingMask = [.width, .height]
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// On the taskbar, right-click menus open above the bar (like Windows) instead of at the pointer,
    /// where they would cover the bar.
    var opensMenusAbove = false

    override func rightMouseDown(with event: NSEvent) {
        if !popUpMenuAbove(for: event) { super.rightMouseDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), popUpMenuAbove(for: event) { return }
        super.mouseDown(with: event)
    }

    private func popUpMenuAbove(for event: NSEvent) -> Bool {
        guard opensMenusAbove, let menu = menu(for: event), !menu.items.isEmpty else { return false }
        let local = convert(event.locationInWindow, from: nil)
        // With no positioning item the point is the menu's top-left corner, so lift it by the menu's height.
        let gap: CGFloat = 6
        let y = isFlipped ? -menu.size.height - gap : bounds.maxY + menu.size.height + gap
        menu.popUp(positioning: nil, at: NSPoint(x: local.x, y: y), in: self)
        return true
    }
}

/// Owns the taskbar windows (one per display), the preview popup, and the window tracker.
@MainActor
final class TaskbarController {
    let tracker = WindowTracker()
    let thumbnails = Thumbnails()
    private let prefs: Preferences
    private let library: Library
    private let previewModel = PreviewModel()
    private let hoverModel = HoverModel()
    /// Where each hoverable element is on screen, keyed by its id.
    /// Where each hoverable element is on screen, one table per taskbar (one per display), keyed by element id.
    /// Every bar has the same ids ("start", app paths…), so they must not share a table.
    private var hoverZones: [[String: (target: PreviewTarget?, rect: NSRect, owner: UUID)]] = []
    /// Hover highlight state for each bar's buttons (the shared `hoverModel` is for the preview popup).
    private var barHovers: [HoverModel] = []
    /// The hovered element as "bar|id", or nil.
    private var hoveredKey: String?
    private var pointerTimer: Timer?
    private var bars: [TaskbarPanel] = []
    private var previewPanel: TaskbarPanel?
    private var hoverWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var previewHovered = false
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var rightClickMonitor: Any?
    /// The button that was right-clicked; no preview for it until the pointer leaves it.
    private var previewSuppressedFor: String?

    /// Opens the Start menu above the given button frame (screen coordinates).
    var onStart: (NSRect) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
    var onSnip: () -> Void = {}

    init(prefs: Preferences, library: Library) {
        self.prefs = prefs
        self.library = library
    }

    func start() {
        prefs.$data.map(\.taskbar).removeDuplicates()
            .sink { [weak self] settings in self?.apply(settings) }
            .store(in: &cancellables)
        // A right-click (or Control-click) on the bar opens a menu: close the preview so it can't cover it,
        // and keep it closed until the pointer moves on to another button.
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            let isMenuClick = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            if isMenuClick, self.bars.contains(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
                self.hidePreviewNow()
                self.previewSuppressedFor = self.hoveredKey
            }
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.rebuildBars(self.prefs.data.taskbar)
            }
        }
        // Forget previews of closed windows.
        tracker.$apps
            .sink { [weak self] apps in
                self?.thumbnails.prune(keeping: Set(apps.flatMap { $0.windows.map(\.id) }))
                self?.refitPreview(apps)
            }
            .store(in: &cancellables)
    }

    /// Height of the bar for the current settings.
    var barHeight: CGFloat { TaskbarView.rowHeight * CGFloat(prefs.data.taskbar.rows) }

    /// Top edge of the taskbar on the screen containing the point, if a bar is showing there.
    func barTop(on screen: NSScreen) -> CGFloat? {
        bars.contains { $0.screen == screen || $0.frame.intersects(screen.frame) }
            ? screen.frame.minY + barHeight : nil
    }

    private var lastSettings: TaskbarSettings?

    private func apply(_ settings: TaskbarSettings) {
        tracker.pinnedPaths = settings.pinned
        tracker.orderPaths = settings.order
        // With Keep windows clear on, a hidden Dock sits under the taskbar at its height instead, so macOS
        // keeps zoomed and filled windows above the bar.
        let reserve: CGFloat? = settings.enabled && settings.keepWindowsClear && settings.dockUnderTaskbar
            ? TaskbarView.rowHeight * CGFloat(settings.rows) : nil
        if lastSettings == nil { Dock.reserveHeight = reserve } else { Dock.reserveHeightChanged(to: reserve) }
        // Turning the taskbar off or on while running: show the Dock, or hide it again if the user chose that.
        if let last = lastSettings, last.enabled != settings.enabled {
            if settings.enabled { Dock.rehideAtLaunch(taskbarOn: true) } else { Dock.restoreForQuit() }
        }
        guard settings.enabled else {
            bars.forEach { $0.orderOut(nil) }
            bars = []
            hidePreviewNow()
            tracker.stop()
            pointerTimer?.invalidate()
            pointerTimer = nil
            tracker.adjustFocusedWindow = nil
            lastSettings = settings
            return
        }
        tracker.start()
        if pointerTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.trackPointer() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pointerTimer = timer
        }
        let layoutChanged = lastSettings.map {
            $0.rows != settings.rows || $0.allDisplays != settings.allDisplays || !$0.enabled
        } ?? true
        if layoutChanged || bars.isEmpty { rebuildBars(settings) }
        updateWindowKeeper(settings)
        lastSettings = settings
    }

    private func rebuildBars(_ settings: TaskbarSettings) {
        bars.forEach { $0.orderOut(nil) }
        bars = []
        cancelDrag()
        hoverZones = []
        barHovers = []
        hoveredKey = nil
        guard settings.enabled else { return }
        let screens = settings.allDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        let height = TaskbarView.rowHeight * CGFloat(settings.rows)
        var frames = screens.map { NSRect(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: height) }
        #if DEBUG
        // Debug only (--test-bars N): N taskbars stacked on the first display, to test several displays on one.
        if let i = CommandLine.arguments.firstIndex(of: "--test-bars"), i + 1 < CommandLine.arguments.count,
           let count = Int(CommandLine.arguments[i + 1]), let first = frames.first {
            frames = (0..<count).map { first.offsetBy(dx: 0, dy: CGFloat($0) * 160) }
        }
        #endif
        for (index, frame) in frames.enumerated() {
            let panel = TaskbarPanel(frame: frame)
            let barHover = HoverModel()
            hoverZones.append([:])
            barHovers.append(barHover)
            let view = TaskbarView(barFrame: frame, actions: actions(for: index))
                .environmentObject(prefs)
                .environmentObject(library)
                .environmentObject(tracker)
                .environmentObject(barHover)
            let host = FirstClickHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: frame.size)
            host.opensMenusAbove = true
            panel.contentView = host
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            bars.append(panel)
        }
        updateWindowKeeper(settings)
    }

    private func actions(for bar: Int) -> TaskbarActions {
        TaskbarActions(
            start: { [weak self] rect in self?.hidePreviewNow(); self?.onStart(rect) },
            register: { [weak self] id, target, rect, owner in
                guard let self, self.hoverZones.indices.contains(bar) else { return }
                if rect.isEmpty {
                    // Only the view that made the entry may remove it. When SwiftUI rebuilds a button (after a
                    // reorder, or as windows come and go), the new copy can register before the old one leaves.
                    if self.hoverZones[bar][id]?.owner == owner { self.hoverZones[bar][id] = nil }
                } else {
                    self.hoverZones[bar][id] = (target, rect, owner)
                }
            },
            showPreview: { [weak self] target, rect in self?.showPreview(target, at: rect) },
            hidePreview: { [weak self] in self?.hidePreviewNow() },
            openSettings: { [weak self] in self?.onOpenSettings() },
            calendar: { [weak self] rect in self?.toggleCalendar(below: rect) },
            snip: { [weak self] in self?.onSnip() },
            dragMoved: { [weak self] path, window, point in self?.dragMoved(bar: bar, path: path, window: window, point: point) },
            dragEnded: { [weak self] path, window, point in self?.dragEnded(bar: bar, path: path, window: window, point: point) },
            dragCancelled: { [weak self] in self?.cancelDrag() }
        )
    }

    // MARK: Keeping windows clear of the bar

    /// Shrinks the focused window when macOS sized it to fill the screen (double-clicking the title bar,
    /// Zoom, Fill or tiling) and that put its bottom edge behind the taskbar. A window the user dragged or
    /// resized there by hand is left alone.
    private func updateWindowKeeper(_ settings: TaskbarSettings) {
        guard settings.enabled, settings.keepWindowsClear, let primary = NSScreen.screens.first else {
            tracker.adjustFocusedWindow = nil
            return
        }
        // Accessibility uses top-left coordinates measured from the primary screen.
        let primaryHeight = primary.frame.maxY
        let height = TaskbarView.rowHeight * CGFloat(settings.rows)
        let screens = settings.allDisplays ? NSScreen.screens : [primary]
        let zones: [(screen: CGRect, usable: CGRect, barTop: CGFloat)] = screens.map { screen in
            let f = screen.frame
            let v = screen.visibleFrame
            let ax = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            let usable = CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height)
            return (ax, usable, ax.maxY - height)
        }
        tracker.adjustFocusedWindow = { window in
            if WindowTracker.bool(window, "AXFullScreen") == true { return }
            guard let frame = WindowTracker.frame(window),
                  let zone = zones.first(where: { $0.screen.contains(CGPoint(x: frame.midX, y: frame.minY + 10)) })
            else { return }
            // Only a window that runs from the top of the usable area to its bottom, the way macOS sizes
            // a filled, zoomed or tiled window.
            let slack: CGFloat = 6
            guard abs(frame.minY - zone.usable.minY) <= slack,
                  frame.maxY >= zone.usable.maxY - slack,
                  frame.maxY > zone.barTop + 1 else { return }
            WindowTracker.setSize(window, CGSize(width: frame.width, height: zone.barTop - frame.minY))
        }
    }

    // MARK: Dragging buttons to reorder

    private var isDraggingButton = false
    /// Where a dragged button would land: next to this app's button (or one of its windows), before or after it.
    private var dropTarget: (path: String, window: CGWindowID?, before: Bool)?

    /// The app a hover zone's button belongs to, if the zone is an app or window button.
    private func appPath(for target: PreviewTarget?) -> String? {
        switch target {
        case .app(let path): return path
        case .window(let id): return tracker.apps.first { $0.windows.contains { $0.id == id } }?.path
        case nil: return nil
        }
    }

    private func dragMoved(bar: Int, path: String, window: CGWindowID?, point: NSPoint) {
        guard bars.indices.contains(bar), hoverZones.indices.contains(bar) else { return }
        if !isDraggingButton {
            isDraggingButton = true
            hidePreviewNow()
            barHovers[bar].draggingPath = path
            barHovers[bar].draggingWindow = window
        }
        let barFrame = bars[bar].frame
        // Let go well away from the bar and nothing changes.
        guard barFrame.insetBy(dx: 0, dy: -30).contains(point) else {
            dropTarget = nil
            barHovers[bar].dropLine = nil
            return
        }
        // A window's button can land between its own app's other windows; anything else lands next to
        // another app (and moves its whole app there).
        let buttons = hoverZones[bar].values.compactMap { zone -> (path: String, window: CGWindowID?, rect: NSRect)? in
            guard let p = appPath(for: zone.target), barFrame.intersects(zone.rect) else { return nil }
            let zoneWindow: CGWindowID? = { if case .window(let id) = zone.target { return id } else { return nil } }()
            if p == path {
                guard let window, let zoneWindow, zoneWindow != window else { return nil }
            }
            return (p, zoneWindow, zone.rect)
        }
        guard !buttons.isEmpty else { return }
        // Prefer buttons on the pointer's row, then the one nearest the pointer sideways.
        let rowDistance = { (r: NSRect) -> CGFloat in point.y < r.minY ? r.minY - point.y : (point.y > r.maxY ? point.y - r.maxY : 0) }
        let nearestRow = buttons.map { rowDistance($0.rect) }.min() ?? 0
        let row = buttons.filter { rowDistance($0.rect) <= nearestRow + 0.5 }
        guard let target = row.min(by: { abs($0.rect.midX - point.x) < abs($1.rect.midX - point.x) }) else { return }
        let before = point.x < target.rect.midX
        dropTarget = (target.path, target.window, before)
        let x = before ? target.rect.minX - 1 : target.rect.maxX + 1
        barHovers[bar].dropLine = CGRect(x: x - barFrame.minX, y: barFrame.maxY - target.rect.maxY + 4,
                                         width: 3, height: target.rect.height - 8)
    }

    private func dragEnded(bar: Int, path: String, window: CGWindowID?, point: NSPoint) {
        dragMoved(bar: bar, path: path, window: window, point: point)
        if let target = dropTarget, let window, target.path == path, let targetWindow = target.window {
            // Reordering one window within its own app's group.
            tracker.moveWindow(window, nextTo: targetWindow, before: target.before)
        } else if let target = dropTarget, target.path != path {
            let visible = tracker.apps.map(\.path)
            var order = visible
            order.removeAll { $0 == path }
            if let i = order.firstIndex(of: target.path) {
                order.insert(path, at: target.before ? i : i + 1)
                // Apps that aren't on the bar right now keep their remembered place after the ones that are.
                let current = Set(visible)
                order += prefs.data.taskbar.order.filter { !current.contains($0) }
                prefs.data.taskbar.order = order
                // Pinned apps follow the same order, so the list in Settings matches the taskbar.
                let pinned = Set(prefs.data.taskbar.pinned)
                let reordered = order.filter { pinned.contains($0) }
                prefs.data.taskbar.pinned = reordered + prefs.data.taskbar.pinned.filter { !reordered.contains($0) }
            }
        }
        cancelDrag()
    }

    /// Clears any drag in progress (the button went away, the bars were rebuilt, or the mouse is up).
    private func cancelDrag() {
        dropTarget = nil
        isDraggingButton = false
        barHovers.forEach { $0.draggingPath = nil; $0.draggingWindow = nil; $0.dropLine = nil }
    }

    // MARK: Pointer tracking

    /// Works out what the pointer is over. SwiftUI's own hover events need the window's app to be
    /// active, which the taskbar's app never is, so the pointer position is checked directly instead.
    private func trackPointer() {
        let point = NSEvent.mouseLocation
        if isDraggingButton && NSEvent.pressedMouseButtons & 1 == 0 { cancelDrag() }

        if let panel = previewPanel, panel.isVisible, panel.frame.contains(point) {
            previewHovered = true
            hideWork?.cancel()
            let items = PreviewView.windows(for: previewModel.target, in: tracker.apps)
            let step = PreviewView.cardWidth + 6
            let offset = point.x - panel.frame.minX - 6
            let index = Int(offset / step)
            if index >= 0, index < items.count, offset - CGFloat(index) * step <= PreviewView.cardWidth {
                let cardRight = panel.frame.minX + 6 + CGFloat(index) * step + PreviewView.cardWidth
                let closeHover = point.x >= cardRight - 30 && point.y >= panel.frame.maxY - 36
                set(card: items[index].1.id, close: closeHover)
            } else {
                set(card: nil, close: false)
            }
            setHovered(bar: nil, id: nil, target: nil, rect: .zero, notify: false)
            return
        }
        if previewHovered {
            previewHovered = false
            set(card: nil, close: false)
            scheduleHide()
        }

        guard let bar = bars.firstIndex(where: { $0.frame.contains(point) }), hoverZones.indices.contains(bar) else {
            setHovered(bar: nil, id: nil, target: nil, rect: .zero)
            return
        }
        let hit = hoverZones[bar].first { $0.value.rect.contains(point) }
        setHovered(bar: bar, id: hit?.key, target: hit?.value.target, rect: hit?.value.rect ?? .zero)
    }

    private func setHovered(bar: Int?, id: String?, target: PreviewTarget?, rect: NSRect, notify: Bool = true) {
        let key = id.flatMap { id in bar.map { "\($0)|\(id)" } }
        guard hoveredKey != key else { return }
        hoveredKey = key
        for (index, model) in barHovers.enumerated() {
            let value = index == bar ? id : nil
            if model.hoveredID != value { model.hoveredID = value }
        }
        if key != previewSuppressedFor { previewSuppressedFor = nil }
        if notify { hover(previewSuppressedFor == nil ? target : nil, rect) }
        if notify && previewSuppressedFor == nil { updateNameTip(target, rect) } else { hideNameTip() }
    }

    // MARK: Name tip

    private var tipPanel: TaskbarPanel?
    private var tipWork: DispatchWorkItem?

    /// An app button with nothing to preview (not open, or no windows) shows the app's name above it after
    /// a moment, like a tooltip. (SwiftUI's own tooltips don't appear in the taskbar's background panels.)
    private func updateNameTip(_ target: PreviewTarget?, _ rect: NSRect) {
        hideNameTip()
        guard case .app(let path)? = target, !isDraggingButton else { return }
        let hasPreview = prefs.data.taskbar.showPreviews && !PreviewView.windows(for: .app(path), in: tracker.apps).isEmpty
        guard !hasPreview else { return }
        let name = tracker.apps.first { $0.path == path }?.name
            ?? (FileManager.default.displayName(atPath: path) as NSString).deletingPathExtension
        let work = DispatchWorkItem { [weak self] in self?.showNameTip(name, above: rect) }
        tipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func showNameTip(_ name: String, above rect: NSRect) {
        let font = NSFont.systemFont(ofSize: 12)
        let textWidth = ceil((name as NSString).size(withAttributes: [.font: font]).width)
        let size = NSSize(width: textWidth + 20, height: 24)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else { return }
        let x = min(max(rect.midX - size.width / 2, screen.frame.minX + 4), screen.frame.maxX - size.width - 4)
        let panel = tipPanel ?? {
            let p = TaskbarPanel(frame: .zero)
            p.level = .popUpMenu
            p.hasShadow = true
            p.ignoresMouseEvents = true
            tipPanel = p
            return p
        }()
        let host = FirstClickHostingView(rootView: NameTip(name: name))
        panel.contentView = host
        panel.setFrame(NSRect(x: x, y: rect.maxY + 8, width: size.width, height: size.height), display: true)
        host.frame = NSRect(origin: .zero, size: size)
        panel.orderFrontRegardless()
    }

    private func hideNameTip() {
        tipWork?.cancel()
        tipWork = nil
        tipPanel?.orderOut(nil)
    }

    private func set(card: CGWindowID?, close: Bool) {
        if hoverModel.previewCard != card { hoverModel.previewCard = card }
        if hoverModel.previewClose != close { hoverModel.previewClose = close }
    }

    // MARK: Previews

    private func hover(_ target: PreviewTarget?, _ rect: NSRect) {
        hoverWork?.cancel()
        guard prefs.data.taskbar.showPreviews, dropTarget == nil, !isDraggingButton else { return }
        if let target {
            hideWork?.cancel()
            let alreadyOpen = previewPanel?.isVisible == true
            let work = DispatchWorkItem { [weak self] in self?.showPreview(target, at: rect) }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (alreadyOpen ? 0.05 : 0.45), execute: work)
        } else {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.previewHovered else { return }
            // The name tip follows the hovered button on its own; this only closes the preview.
            self.hidePreviewOnly()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// The button the preview popup is lined up with, and how many cards it was sized for.
    private var previewAnchor = NSRect.zero
    private var previewCount = 0

    func showPreview(_ target: PreviewTarget, at rect: NSRect) {
        let items = PreviewView.windows(for: target, in: tracker.apps)
        // Nothing to preview: close only the preview. The app's name tip (timed the same) must stay.
        guard !items.isEmpty else { return hidePreviewOnly() }
        hideWork?.cancel()
        previewModel.target = target
        previewAnchor = rect
        thumbnails.capture(items.map(\.1))
        placePreview(count: items.count)
        previewPanel?.orderFrontRegardless()
    }

    /// Resizes the open preview when its windows change (one closed or opened), or hides it when none are left.
    private func refitPreview(_ apps: [TaskApp]) {
        guard let panel = previewPanel, panel.isVisible, let target = previewModel.target else { return }
        let count = PreviewView.windows(for: target, in: apps).count
        if count == 0 { return hidePreviewNow() }
        // Wait for SwiftUI to drop the closed window's card, then fit the popup to what's left.
        if count != previewCount { DispatchQueue.main.async { [weak self] in self?.placePreview(count: count) } }
    }

    private func placePreview(count: Int) {
        let rect = previewAnchor
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else { return }
        previewCount = count
        let width = CGFloat(count) * (PreviewView.cardWidth + 6) + 6
        let height = PreviewView.cardHeight + 12
        let visible = screen.frame
        let x = min(max(rect.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        let frame = NSRect(x: x, y: rect.maxY + 10, width: width, height: height)

        let panel = previewPanel ?? makePreviewPanel()
        panel.setFrame(frame, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
    }

    func hidePreviewNow() {
        hideNameTip()
        hidePreviewOnly()
    }

    private func hidePreviewOnly() {
        hoverWork?.cancel()
        hideWork?.cancel()
        previewHovered = false
        previewPanel?.orderOut(nil)
        previewModel.target = nil
    }

    // MARK: Calendar

    private let calendarModel = CalendarModel()
    private var calendarPanel: TaskbarPanel?
    private var calendarClock = NSRect.zero
    private var clickMonitors: [Any] = []

    private func toggleCalendar(below clock: NSRect) {
        if calendarPanel?.isVisible == true { return hideCalendar() }
        hidePreviewNow()
        let panel = calendarPanel ?? makeCalendarPanel()
        calendarModel.openCount += 1
        calendarClock = clock

        // Size it to its content, then line its right edge up with the clock, just above the bar.
        guard let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = NSSize(width: CalendarPopup.width, height: ceil(host.fittingSize.height))
        let screen = NSScreen.screens.first { $0.frame.intersects(clock) } ?? NSScreen.main ?? NSScreen.screens[0]
        let x = min(max(clock.maxX - size.width + 6, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        let frame = NSRect(x: x, y: screen.frame.minY + barHeight + 10, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        // SwiftUI may resize the window once its content lays out, and AppKit keeps the top edge fixed when
        // that happens, which would push the bottom below the screen. Keep the bottom edge just above the bar.
        let bottomLeft = frame.origin
        for delay in [0.0, 0.05, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak panel] in
                guard let panel, panel.isVisible, panel.frame.origin != bottomLeft else { return }
                panel.setFrameOrigin(bottomLeft)
            }
        }

        // Any click outside the calendar closes it (the clock itself toggles it instead).
        let outside: (NSPoint) -> Bool = { [weak self] point in
            guard let self, let panel = self.calendarPanel else { return false }
            return !panel.frame.contains(point) && !self.calendarClock.contains(point)
        }
        clickMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hideCalendar() }
        } as Any)
        clickMonitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if outside(NSEvent.mouseLocation) { Task { @MainActor in self?.hideCalendar() } }
            return event
        } as Any)
    }

    #if DEBUG
    /// Debug only (--demo --taskbar): opens the Start menu and the calendar from their real buttons.
    func stageDemo() {
        if let start = hoverZones.first?["start"]?.rect { onStart(start) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if let clock = self?.hoverZones.first?["clock"]?.rect { self?.toggleCalendar(below: clock) }
        }
    }

    /// Debug only: the Start button's screen rect on each bar, for tests.
    func startButtonRects() -> [NSRect] {
        hoverZones.compactMap { $0["start"]?.rect }
    }

    /// Debug only: each app button on the first bar, left to right, as "Name@x,y" (screen centre).
    func buttonCentres() -> String {
        guard let zones = hoverZones.first else { return "" }
        return zones.values.compactMap { z -> (String, NSRect)? in
            guard let p = appPath(for: z.target), bars.first?.frame.intersects(z.rect) == true else { return nil }
            var name = (p as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            name = name.replacingOccurrences(of: " ", with: "_")
            if case .window(let id) = z.target { name += "#\(id)" }
            return (name, z.rect)
        }
        .sorted { $0.1.minX < $1.1.minX }
        .map { "\($0.0)@\(Int($0.1.midX)),\(Int($0.1.midY))" }
        .joined(separator: " ")
    }

    /// Debug only: which bar shows a hover highlight, and on what.
    func hoverState() -> String {
        barHovers.enumerated().map { "bar\($0.offset)=\($0.element.hoveredID ?? "-")" }.joined(separator: " ")
    }

    /// Debug only (--calendar): opens the calendar as if the clock at the bottom-right was clicked.
    func showCalendarForTesting() {
        guard let f = NSScreen.screens.first?.frame else { return }
        toggleCalendar(below: NSRect(x: f.maxX - 120, y: f.minY + 4, width: 100, height: 40))
    }
    #endif

    func hideCalendar() {
        clickMonitors.forEach { NSEvent.removeMonitor($0) }
        clickMonitors = []
        calendarPanel?.orderOut(nil)
    }

    private func makeCalendarPanel() -> TaskbarPanel {
        let panel = TaskbarPanel(frame: .zero)
        panel.level = .popUpMenu
        panel.hasShadow = true
        let view = CalendarPopup()
            .environmentObject(prefs)
            .environmentObject(calendarModel)
        panel.contentView = FirstClickHostingView(rootView: view)
        calendarPanel = panel
        return panel
    }

    private func makePreviewPanel() -> TaskbarPanel {
        let panel = TaskbarPanel(frame: .zero)
        panel.level = .popUpMenu
        panel.hasShadow = true
        let view = PreviewView(onDone: { [weak self] in self?.hidePreviewNow() })
        .environmentObject(previewModel)
        .environmentObject(tracker)
        .environmentObject(thumbnails)
        .environmentObject(prefs)
        .environmentObject(hoverModel)
        panel.contentView = FirstClickHostingView(rootView: view)
        previewPanel = panel
        return panel
    }
}

/// The app name shown above a taskbar button that has no window preview.
private struct NameTip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(white: 0.16).opacity(0.96)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
    }
}
