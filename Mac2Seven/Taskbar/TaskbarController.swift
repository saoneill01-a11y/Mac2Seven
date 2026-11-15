import AppKit
import Combine
import SwiftUI

/// Borderless bar along the bottom of a screen. It never takes focus, so clicking it doesn't steal
/// the keyboard from the app you're using.
final class TaskbarPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
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
}

/// Owns the taskbar windows (one per display), the preview popup, and the window tracker.
@MainActor
final class TaskbarController {
    let tracker = WindowTracker()
    let thumbnails = Thumbnails()
    private let prefs: Preferences
    private let previewModel = PreviewModel()
    private let hoverModel = HoverModel()
    /// Where each hoverable element is on screen, keyed by its id.
    private var hoverZones: [String: (target: PreviewTarget?, rect: NSRect)] = [:]
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

    init(prefs: Preferences) {
        self.prefs = prefs
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
                self.previewSuppressedFor = self.hoverModel.hoveredID
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
        hoverZones = [:]
        guard settings.enabled else { return }
        let screens = settings.allDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        let height = TaskbarView.rowHeight * CGFloat(settings.rows)
        for screen in screens {
            let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: height)
            let panel = TaskbarPanel(frame: frame)
            let view = TaskbarView(barFrame: frame, actions: actions)
                .environmentObject(prefs)
                .environmentObject(tracker)
                .environmentObject(hoverModel)
            let host = FirstClickHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: frame.size)
            panel.contentView = host
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            bars.append(panel)
        }
        updateWindowKeeper(settings)
    }

    private var actions: TaskbarActions {
        TaskbarActions(
            start: { [weak self] rect in self?.hidePreviewNow(); self?.onStart(rect) },
            register: { [weak self] id, target, rect in
                if rect.isEmpty { self?.hoverZones[id] = nil } else { self?.hoverZones[id] = (target, rect) }
            },
            showPreview: { [weak self] target, rect in self?.showPreview(target, at: rect) },
            hidePreview: { [weak self] in self?.hidePreviewNow() },
            openSettings: { [weak self] in self?.onOpenSettings() },
            calendar: { [weak self] rect in self?.toggleCalendar(below: rect) }
        )
    }

    // MARK: Keeping windows clear of the bar

    /// Shrinks the focused window when its bottom edge is behind the taskbar.
    private func updateWindowKeeper(_ settings: TaskbarSettings) {
        guard settings.enabled, settings.keepWindowsClear, let primary = NSScreen.screens.first else {
            tracker.adjustFocusedWindow = nil
            return
        }
        // Accessibility uses top-left coordinates measured from the primary screen.
        let primaryHeight = primary.frame.maxY
        let height = TaskbarView.rowHeight * CGFloat(settings.rows)
        let screens = settings.allDisplays ? NSScreen.screens : [primary]
        let zones: [(screen: CGRect, barTop: CGFloat)] = screens.map { screen in
            let f = screen.frame
            let ax = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            return (ax, ax.maxY - height)
        }
        tracker.adjustFocusedWindow = { window in
            if WindowTracker.bool(window, "AXFullScreen") == true { return }
            guard let frame = WindowTracker.frame(window),
                  let zone = zones.first(where: { $0.screen.contains(CGPoint(x: frame.midX, y: frame.minY + 10)) })
            else { return }
            // Leave windows that are mostly below the bar, or tiny, alone.
            guard frame.maxY > zone.barTop + 1, frame.minY < zone.barTop - 150 else { return }
            WindowTracker.setSize(window, CGSize(width: frame.width, height: zone.barTop - frame.minY))
        }
    }

    // MARK: Pointer tracking

    /// Works out what the pointer is over. SwiftUI's own hover events need the window's app to be
    /// active, which the taskbar's app never is, so the pointer position is checked directly instead.
    private func trackPointer() {
        let point = NSEvent.mouseLocation

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
            setHovered(nil, target: nil, rect: .zero, notify: false)
            return
        }
        if previewHovered {
            previewHovered = false
            set(card: nil, close: false)
            scheduleHide()
        }

        guard bars.contains(where: { $0.frame.contains(point) }) else {
            setHovered(nil, target: nil, rect: .zero)
            return
        }
        let hit = hoverZones.first { $0.value.rect.contains(point) }
        setHovered(hit?.key, target: hit?.value.target, rect: hit?.value.rect ?? .zero)
    }

    private func setHovered(_ id: String?, target: PreviewTarget?, rect: NSRect, notify: Bool = true) {
        guard hoverModel.hoveredID != id else { return }
        hoverModel.hoveredID = id
        if id != previewSuppressedFor { previewSuppressedFor = nil }
        if notify { hover(previewSuppressedFor == nil ? target : nil, rect) }
    }

    private func set(card: CGWindowID?, close: Bool) {
        if hoverModel.previewCard != card { hoverModel.previewCard = card }
        if hoverModel.previewClose != close { hoverModel.previewClose = close }
    }

    // MARK: Previews

    private func hover(_ target: PreviewTarget?, _ rect: NSRect) {
        hoverWork?.cancel()
        guard prefs.data.taskbar.showPreviews else { return }
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
            self.hidePreviewNow()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// The button the preview popup is lined up with, and how many cards it was sized for.
    private var previewAnchor = NSRect.zero
    private var previewCount = 0

    func showPreview(_ target: PreviewTarget, at rect: NSRect) {
        let items = PreviewView.windows(for: target, in: tracker.apps)
        guard !items.isEmpty else { return hidePreviewNow() }
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
