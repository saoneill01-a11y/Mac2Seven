import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

/// What the toolbar shows and changes.
@MainActor
final class SnipModel: ObservableObject {
    @Published var mode: SnipMode = .rectangle
    @Published var delay = 0
    @Published var hasSelection = false
    @Published var countdown: Int?
}

/// One finished capture, kept for the thumbnail's right-click menu.
final class SnipShot {
    let png: Data
    let image: NSImage
    /// The file in the screenshots folder (or wherever it was last saved), if any.
    var file: URL?
    /// A temporary copy for Preview or Photos when it wasn't saved.
    var tempFile: URL?

    init(png: Data, image: NSImage, file: URL?) {
        self.png = png
        self.image = image
        self.file = file
    }
}

/// Mac2Seven Snip: pick an area, window, display or freeform shape, then capture it to the clipboard,
/// a file in the Screenshots folder, and Preview.
@MainActor
final class SnipController {
    let model = SnipModel()
    private let prefs: Preferences
    private var settings: SnipSettings { prefs.data.snip }

    private var overlayWindows: [SnipOverlayWindow] = []
    private var overlayViews: [SnipOverlayView] = []
    private var toolbar: TaskbarPanel?
    private var countdownPanel: TaskbarPanel?
    private var thumbnailPanel: TaskbarPanel?
    private var thumbnailHide: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private(set) var isActive = false
    /// The app that was in front when Snip opened; it gets the keyboard back when Snip closes.
    private var previousApp: NSRunningApplication?
    /// Pixels per point of the last capture, so the clipboard image has the right size on any display.
    private var captureScale: CGFloat = 2

    /// The current rectangle, on one display, in that display's points (origin bottom-left).
    private(set) var selection: (screen: NSScreen, rect: NSRect)?
    /// The finished freeform shape, on one display, in the same coordinates. It stays until captured.
    private(set) var shape: (screen: NSScreen, path: NSBezierPath)?
    /// Visible windows, front to back, as captured when Snip opened (global Cocoa coordinates).
    private var windowList: [(id: CGWindowID, frame: NSRect)] = []
    private var hoverWindow: CGWindowID?
    var hoverWindowRect: NSRect? { windowList.first { $0.id == hoverWindow }?.frame }

    /// Called before Snip opens (to close the Start menu, previews and so on).
    var onWillStart: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    /// Where the thumbnail should sit above (the taskbar's height, or 0).
    var bottomInset: () -> CGFloat = { 0 }

    init(prefs: Preferences) {
        self.prefs = prefs
        model.$mode.dropFirst().removeDuplicates().sink { [weak self] mode in
            guard let self else { return }
            if self.prefs.data.snip.mode != mode { self.prefs.data.snip.mode = mode }
            self.setSelection(nil)
            self.setShape(nil)
            self.overlayViews.forEach { $0.resetFreeform() }
            if mode == .window { self.updateHoverWindow() }
            if mode == .rectangle { self.restoreLastRect() }
            self.redrawAll()
        }.store(in: &cancellables)
        model.$delay.dropFirst().removeDuplicates().sink { [weak self] delay in
            if self?.prefs.data.snip.delay != delay { self?.prefs.data.snip.delay = delay }
        }.store(in: &cancellables)
    }

    // MARK: Opening and closing

    func start() {
        guard !isActive else { return }
        guard CGPreflightScreenCaptureAccess() else { return askForPermission() }
        onWillStart()
        isActive = true
        model.mode = settings.mode
        model.delay = settings.delay
        model.countdown = nil
        selection = nil
        model.hasSelection = false
        loadWindowList()

        for screen in NSScreen.screens {
            let window = SnipOverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.acceptsMouseMovedEvents = true
            // Set explicitly: otherwise clicks on fully clear pixels (inside the selection) pass through
            // to the app underneath instead of reaching Snip.
            window.ignoresMouseEvents = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let view = SnipOverlayView(screen: screen, controller: self)
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            overlayWindows.append(window)
            overlayViews.append(view)
        }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate()
        let mouseScreen = screenUnderMouse()
        if let i = overlayViews.firstIndex(where: { $0.screen == mouseScreen }) {
            overlayWindows[i].makeKeyAndOrderFront(nil)
            overlayWindows[i].makeFirstResponder(overlayViews[i])
        }
        showToolbar(on: mouseScreen)
        if model.mode == .window { updateHoverWindow() }
        if model.mode == .rectangle { restoreLastRect() }
        NSCursor.crosshair.set()
    }

    func cancel() {
        tearDown()
    }

    /// Closes Snip. `returnFocus` is false when Preview is about to open with the capture (it takes focus).
    private func tearDown(returnFocus: Bool = true) {
        if returnFocus, isActive, let app = previousApp, !app.isTerminated { app.activate() }
        previousApp = nil
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows = []
        overlayViews = []
        toolbar?.orderOut(nil)
        countdownPanel?.orderOut(nil)
        selection = nil
        shape = nil
        model.hasSelection = false
        model.countdown = nil
        hoverWindow = nil
        isActive = false
        NSCursor.arrow.set()
    }

    func openSettings() {
        cancel()
        onOpenSettings()
    }

    private func askForPermission() {
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "Mac2Seven needs Screen Recording permission to take screenshots"
        alert.informativeText = "Turn on Mac2Seven in System Settings → Privacy & Security → Screen Recording, then try again. You may need to quit and reopen Mac2Seven afterwards."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: State used by the overlays

    func setSelection(_ value: (NSScreen, NSRect)?) {
        selection = value.map { (screen: $0.0, rect: $0.1) }
        if value != nil { shape = nil }
        model.hasSelection = selection != nil || shape != nil
        redrawAll()
    }

    func setShape(_ value: (NSScreen, NSBezierPath)?) {
        shape = value.map { (screen: $0.0, path: $0.1) }
        if value != nil { selection = nil }
        model.hasSelection = selection != nil || shape != nil
        redrawAll()
    }

    func redrawAll() {
        overlayViews.forEach { $0.needsDisplay = true }
    }

    private func loadWindowList() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        windowList = info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: dict),
                  cg.width > 40, cg.height > 40 else { return nil }
            // Window-server rects are top-left based; flip to Cocoa's bottom-left.
            return (id, NSRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height))
        }
    }

    func updateHoverWindow() {
        let point = NSEvent.mouseLocation
        let next = windowList.first { $0.frame.contains(point) }?.id
        if next != hoverWindow {
            hoverWindow = next
            redrawAll()
        }
    }

    /// Draws the last rectangle captured, on the same display, if that display is still connected and it fits.
    private func restoreLastRect() {
        guard isActive, selection == nil, let rect = settings.lastRect, rect.width >= 4, rect.height >= 4,
              let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == settings.lastRectDisplay }),
              NSRect(origin: .zero, size: screen.frame.size).contains(rect),
              overlayViews.contains(where: { $0.screen == screen }) else { return }
        setSelection((screen, rect))
    }

    static func displayID(of screen: NSScreen) -> UInt32? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }

    private func screenUnderMouse() -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: Capturing

    /// The toolbar's Capture button, or Return.
    func captureNow() {
        switch model.mode {
        case .rectangle:
            guard let s = selection else { return NSSound.beep() }
            prefs.data.snip.lastRect = s.rect
            prefs.data.snip.lastRectDisplay = Self.displayID(of: s.screen)
            run { await self.captureArea(s.rect, on: s.screen) }
        case .fullScreen:
            captureScreen(screenUnderMouse())
        case .window:
            captureHoveredWindow()
        case .freeform:
            guard let s = shape else { return NSSound.beep() }
            captureFreeform(s.path, on: s.screen)
        }
    }

    func captureScreen(_ screen: NSScreen) {
        run { await self.captureArea(NSRect(origin: .zero, size: screen.frame.size), on: screen) }
    }

    func captureHoveredWindow() {
        guard let id = hoverWindow else { return NSSound.beep() }
        run { await self.captureWindow(id) }
    }

    func captureFreeform(_ path: NSBezierPath, on screen: NSScreen) {
        run { await self.captureShape(path, on: screen) }
    }

    /// Hides Snip's own windows, waits out the timer, then captures and delivers the image.
    private func run(_ capture: @escaping () async -> CGImage?) {
        overlayWindows.forEach { $0.orderOut(nil) }
        toolbar?.orderOut(nil)
        NSCursor.arrow.set()
        let delay = model.delay
        Task { @MainActor in
            if delay > 0 {
                for remaining in stride(from: delay, to: 0, by: -1) {
                    self.showCountdown(remaining)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                self.countdownPanel?.orderOut(nil)
            }
            // Give the window server a moment to take Snip's windows off the screen.
            try? await Task.sleep(nanoseconds: 180_000_000)
            let image = await capture()
            self.tearDown(returnFocus: image == nil || !self.settings.openInPreview)
            if let image { self.deliver(image) } else { NSSound.beep() }
        }
    }

    private func captureArea(_ rect: NSRect, on screen: NSScreen) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = screen.backingScaleFactor
        captureScale = scale
        let config = SCStreamConfiguration()
        // ScreenCaptureKit measures from the display's top-left corner.
        config.sourceRect = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
        config.width = max(Int((rect.width * scale).rounded()), 1)
        config.height = max(Int((rect.height * scale).rounded()), 1)
        config.showsCursor = settings.showPointer
        config.scalesToFit = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private func captureWindow(_ id: CGWindowID) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.ignoreShadowsSingleWindow = !settings.windowShadow
        config.showsCursor = settings.showPointer
        let scale = CGFloat(filter.pointPixelScale)
        captureScale = scale
        config.width = max(Int((filter.contentRect.width * scale).rounded()), 1)
        config.height = max(Int((filter.contentRect.height * scale).rounded()), 1)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Captures the shape's bounding box, then makes everything outside the shape transparent.
    private func captureShape(_ path: NSBezierPath, on screen: NSScreen) async -> CGImage? {
        let box = path.bounds.intersection(NSRect(origin: .zero, size: screen.frame.size)).integral
        guard !box.isEmpty, let image = await captureArea(box, on: screen) else { return nil }
        let scale = screen.backingScaleFactor
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let shape = path.copy() as! NSBezierPath
        var transform = AffineTransform(translationByX: -box.minX, byY: -box.minY)
        transform.append(AffineTransform(scaleByX: scale, byY: scale))
        shape.transform(using: transform)
        ctx.addPath(shape.cgPath)
        ctx.clip()
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    #if DEBUG
    /// Debug only (--snip-auto): makes a sample selection for the current mode and captures it.
    func debugCapture() {
        let screen = screenUnderMouse()
        let size = screen.frame.size
        switch model.mode {
        case .rectangle:
            setSelection((screen, NSRect(x: size.width / 2 - 300, y: size.height / 2 - 175, width: 600, height: 350)))
            captureNow()
        case .fullScreen:
            captureScreen(screen)
        case .window:
            hoverWindow = windowList.first?.id
            captureHoveredWindow()
        case .freeform:
            let path = NSBezierPath(ovalIn: NSRect(x: size.width / 2 - 220, y: size.height / 2 - 160, width: 440, height: 320))
            setShape((screen, path))
            captureNow()
        }
    }

    /// Debug only (--snip-move-test): drags a sample rectangle and a sample freeform shape by their middles
    /// with simulated mouse events, and writes where each was before and after.
    func debugMoveTest(report path: String) {
        let screen = screenUnderMouse()
        guard let i = overlayViews.firstIndex(where: { $0.screen == screen }) else { return }
        let view = overlayViews[i], window = overlayWindows[i]
        func send(_ type: NSEvent.EventType, _ p: NSPoint) {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: view.mouseDown(with: e)
            case .leftMouseDragged: view.mouseDragged(with: e)
            default: view.mouseUp(with: e)
            }
        }
        func drag(from a: NSPoint, by d: NSPoint) {
            send(.leftMouseDown, a)
            for step in 1...5 {
                let t = CGFloat(step) / 5
                send(.leftMouseDragged, NSPoint(x: a.x + d.x * t, y: a.y + d.y * t))
            }
            send(.leftMouseUp, NSPoint(x: a.x + d.x, y: a.y + d.y))
        }
        func text(_ r: NSRect) -> String { "x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height))" }
        var lines: [String] = []

        model.mode = .rectangle
        setSelection((screen, NSRect(x: 300, y: 300, width: 400, height: 250)))
        lines.append("rectangle before: " + text(selection!.rect))
        drag(from: NSPoint(x: 500, y: 425), by: NSPoint(x: 150, y: 80))
        lines.append("rectangle after:  " + (selection.map { text($0.rect) } ?? "none"))

        model.mode = .freeform
        setShape((screen, NSBezierPath(ovalIn: NSRect(x: 300, y: 300, width: 400, height: 250))))
        lines.append("freeform before:  " + text(shape!.path.bounds))
        drag(from: NSPoint(x: 500, y: 425), by: NSPoint(x: -120, y: 60))
        lines.append("freeform after:   " + (shape.map { text($0.path.bounds) } ?? "none"))

        drag(from: NSPoint(x: 1000, y: 200), by: NSPoint(x: 120, y: 90))
        lines.append("draw new outside: " + (shape.map { text($0.path.bounds) } ?? "none"))
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        cancel()
    }

    /// Debug only: a sample rectangle so the overlay can be screenshotted mid-selection.
    func debugSelectSample() {
        let screen = screenUnderMouse()
        let size = screen.frame.size
        let rect = NSRect(x: size.width / 2 - 300, y: size.height / 2 - 120, width: 600, height: 350)
        if model.mode == .freeform {
            setShape((screen, NSBezierPath(ovalIn: rect)))
        } else {
            setSelection((screen, rect))
        }
    }
    #endif

    // MARK: Delivering

    private func deliver(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return NSSound.beep() }
        let scale = max(captureScale, 1)
        let pointSize = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let nsImage = NSImage(cgImage: image, size: pointSize)

        var fileURL: URL?
        if settings.autoSave {
            fileURL = save(png, in: URL(fileURLWithPath: settings.saveFolder, isDirectory: true))
        }
        let shot = SnipShot(png: png, image: nsImage, file: fileURL)
        if settings.copyToClipboard { copy(shot) }
        if settings.openInPreview { openInPreview(shot) }
        playSound()
        if settings.showThumbnail { showThumbnail(shot) }
    }

    // MARK: Thumbnail menu actions

    func copy(_ shot: SnipShot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(shot.png, forType: .png)
        if let tiff = shot.image.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    /// The saved file, or a temporary copy for apps that need a file.
    private func fileForOpening(_ shot: SnipShot) -> URL? {
        if let file = shot.file, FileManager.default.fileExists(atPath: file.path) { return file }
        if let temp = shot.tempFile, FileManager.default.fileExists(atPath: temp.path) { return temp }
        shot.tempFile = save(shot.png, in: FileManager.default.temporaryDirectory.appendingPathComponent("Mac2Seven Snips"))
        return shot.tempFile
    }

    private func open(_ shot: SnipShot, with app: String) {
        guard let url = fileForOpening(shot) else { return NSSound.beep() }
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: app),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func openInPreview(_ shot: SnipShot) {
        open(shot, with: "/System/Applications/Preview.app")
    }

    /// Opening an image with Photos imports it into the library.
    func saveToPhotos(_ shot: SnipShot) {
        hideThumbnail()
        open(shot, with: "/System/Applications/Photos.app")
    }

    func save(_ shot: SnipShot, to directory: FileManager.SearchPathDirectory) {
        guard let folder = FileManager.default.urls(for: directory, in: .userDomainMask).first,
              let url = save(shot.png, in: folder) else { return NSSound.beep() }
        if shot.file == nil { shot.file = url }
        hideThumbnail()
    }

    func saveAs(_ shot: SnipShot) {
        hideThumbnail()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (shot.file?.lastPathComponent) ?? "Screenshot " + Self.nameFormat.string(from: Date()) + ".png"
        panel.directoryURL = URL(fileURLWithPath: settings.saveFolder, isDirectory: true)
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try shot.png.write(to: url)
            shot.file = url
        } catch {
            NSSound.beep()
            NSLog("Mac2Seven couldn't save a screenshot to \(url.path): \(error)")
        }
    }

    func showInFinder(_ shot: SnipShot) {
        if let file = shot.file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        hideThumbnail()
    }

    /// Moves the saved file to the Trash.
    func delete(_ shot: SnipShot) {
        if let file = shot.file {
            NSWorkspace.shared.recycle([file]) { _, error in if error != nil { NSSound.beep() } }
            shot.file = nil
        }
        hideThumbnail()
    }

    func hideThumbnail() {
        thumbnailHide?.cancel()
        thumbnailPanel?.orderOut(nil)
    }

    private static let nameFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return f
    }()

    /// Saves as "Screenshot 2026-11-15 at 3.41.02 PM.png" (adding " 2", " 3"… if that name is taken).
    private func save(_ png: Data, in folder: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = "Screenshot " + Self.nameFormat.string(from: Date())
            var url = folder.appendingPathComponent(base + ".png")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(base) \(n).png")
                n += 1
            }
            try png.write(to: url)
            return url
        } catch {
            NSLog("Mac2Seven couldn't save a screenshot in \(folder.path): \(error)")
            return nil
        }
    }

    private func playSound() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if FileManager.default.fileExists(atPath: path) { NSSound(contentsOfFile: path, byReference: true)?.play() }
    }

    // MARK: Toolbar, countdown and thumbnail windows

    private func showToolbar(on screen: NSScreen) {
        let panel = toolbar ?? {
            let p = TaskbarPanel(frame: .zero)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let view = SnipToolbar(controller: self).environmentObject(model).environmentObject(prefs)
            p.contentView = FirstClickHostingView(rootView: view)
            toolbar = p
            return p
        }()
        let size = NSSize(width: SnipToolbar.width, height: SnipToolbar.height)
        let f = screen.frame
        let frame = NSRect(x: f.midX - size.width / 2, y: f.minY + max(bottomInset(), 0) + 40, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    private func showCountdown(_ seconds: Int) {
        model.countdown = seconds
        let panel = countdownPanel ?? {
            let p = TaskbarPanel(frame: .zero)
            p.level = .screenSaver
            p.hasShadow = true
            p.contentView = FirstClickHostingView(rootView: SnipCountdown().environmentObject(model))
            countdownPanel = p
            return p
        }()
        let f = screenUnderMouse().frame
        panel.setFrame(NSRect(x: f.midX - 70, y: f.midY - 70, width: 140, height: 140), display: true)
        panel.orderFrontRegardless()
    }

    private func showThumbnail(_ shot: SnipShot) {
        thumbnailHide?.cancel()
        let image = shot.image
        let width: CGFloat = 220
        let aspect = image.size.height / max(image.size.width, 1)
        let height = min(max(width * aspect, 60), 260)
        let panel = thumbnailPanel ?? {
            let p = TaskbarPanel(frame: .zero)
            p.level = .popUpMenu
            p.hasShadow = true
            thumbnailPanel = p
            return p
        }()
        let view = SnipThumbnail(controller: self, shot: shot)
        panel.contentView = FirstClickHostingView(rootView: view)
        let f = screenUnderMouse().frame
        panel.setFrame(NSRect(x: f.maxX - width - 24, y: f.minY + max(bottomInset(), 0) + 20, width: width, height: height),
                       display: true)
        panel.orderFrontRegardless()
        scheduleThumbnailHide(after: 5)
    }

    /// Hides the thumbnail later, but not while its menu is open or the pointer is on it.
    private func scheduleThumbnailHide(after seconds: Double) {
        let hide = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.thumbnailPanel else { return }
            let menuOpen = RunLoop.current.currentMode == .eventTracking
            if menuOpen || NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
                self.scheduleThumbnailHide(after: 1)
            } else {
                panel.orderOut(nil)
            }
        }
        thumbnailHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: hide)
    }
}
