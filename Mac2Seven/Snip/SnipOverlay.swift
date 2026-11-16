import AppKit

/// Borderless full-screen window that takes the mouse and keyboard while you pick what to capture.
final class SnipOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Dims one display and lets you draw a rectangle, pick a window, pick the display, or draw a freeform shape.
/// Coordinates are this display's own points, origin bottom-left (the window fills the display).
final class SnipOverlayView: NSView {
    weak var controller: SnipController?
    let screen: NSScreen

    private enum Drag {
        case new(start: NSPoint)
        case move(offset: NSPoint)
        case resize(fixed: NSPoint, xEdge: Bool, yEdge: Bool, original: NSRect)
        case moveShape(last: NSPoint)
    }
    private var drag: Drag?
    /// The shape being drawn right now (before the mouse is let go).
    private var freeform: NSBezierPath?

    init(screen: NSScreen, controller: SnipController) {
        self.screen = screen
        self.controller = controller
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    private var mode: SnipMode { controller?.model.mode ?? .rectangle }
    private var selection: NSRect? {
        guard let s = controller?.selection, s.screen == screen else { return nil }
        return s.rect
    }
    /// The finished freeform shape, if it's on this display.
    private var shape: NSBezierPath? {
        guard let s = controller?.shape, s.screen == screen else { return nil }
        return s.path
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let controller else { return }
        // A barely-there tint everywhere, so no pixel is fully clear: macOS sends clicks on fully clear
        // pixels to the window underneath, which made the inside of the selection impossible to drag.
        NSColor.black.withAlphaComponent(0.004).setFill()
        bounds.fill()
        let dim = NSColor.black.withAlphaComponent(0.32)
        let accent = NSColor.controlAccentColor

        switch mode {
        case .rectangle:
            dim.setFill()
            if let rect = selection {
                let path = NSBezierPath(rect: bounds)
                path.append(NSBezierPath(rect: rect))
                path.windingRule = .evenOdd
                path.fill()
                NSColor.white.setStroke()
                let border = NSBezierPath(rect: rect.insetBy(dx: -0.75, dy: -0.75))
                border.lineWidth = 1.5
                border.stroke()
                for corner in corners(of: rect) {
                    let handle = NSRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8)
                    NSColor.white.setFill()
                    NSBezierPath(ovalIn: handle).fill()
                }
                drawSizeLabel(for: rect)
            } else {
                bounds.fill()
            }

        case .window:
            dim.setFill()
            if let global = controller.hoverWindowRect, let rect = local(fromGlobal: global), rect.intersects(bounds) {
                let path = NSBezierPath(rect: bounds)
                path.append(NSBezierPath(rect: rect))
                path.windingRule = .evenOdd
                path.fill()
                accent.withAlphaComponent(0.18).setFill()
                rect.fill()
                accent.setStroke()
                let border = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5))
                border.lineWidth = 3
                border.stroke()
            } else {
                bounds.fill()
            }

        case .fullScreen:
            let here = NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
            (here ? NSColor.black.withAlphaComponent(0.12) : dim).setFill()
            bounds.fill()
            if here {
                accent.setStroke()
                let border = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3))
                border.lineWidth = 6
                border.stroke()
            }

        case .freeform:
            dim.setFill()
            if let outline = freeform ?? shape {
                let path = NSBezierPath(rect: bounds)
                path.append(outline)
                path.windingRule = .evenOdd
                path.fill()
                NSColor.white.setStroke()
                outline.lineWidth = 2
                outline.stroke()
            } else {
                bounds.fill()
            }
        }
    }

    private func corners(of r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
         NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY)]
    }

    private func drawSizeLabel(for rect: NSRect) {
        let scale = screen.backingScaleFactor
        let text = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        var box = NSRect(x: rect.maxX - size.width - 12, y: rect.minY - size.height - 10, width: size.width + 10, height: size.height + 4)
        if box.minY < 4 { box.origin.y = rect.minY + 6 }
        box.origin.x = max(box.origin.x, 4)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: attrs)
    }

    /// Converts a global Cocoa rect (bottom-left origin) to this view's coordinates.
    private func local(fromGlobal rect: NSRect) -> NSRect? {
        NSRect(x: rect.minX - screen.frame.minX, y: rect.minY - screen.frame.minY, width: rect.width, height: rect.height)
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
        switch mode {
        case .window: controller?.updateHoverWindow()
        case .fullScreen: controller?.redrawAll()
        default: break
        }
    }

    #if DEBUG
    private func trace(_ text: String) {
        guard let path = ProcessInfo.processInfo.environment["M2S_SNIP_TRACE"],
              let h = FileHandle(forWritingAtPath: path) ?? { FileManager.default.createFile(atPath: path, contents: nil); return FileHandle(forWritingAtPath: path) }()
        else { return }
        h.seekToEndOfFile(); h.write((text + "\n").data(using: .utf8)!); h.closeFile()
    }
    #else
    private func trace(_ text: String) {}
    #endif

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        defer { trace("down \(Int(p.x)),\(Int(p.y)) drag=\(String(describing: drag))") }
        switch mode {
        case .rectangle:
            if let rect = selection, let resize = resizeDrag(at: p, rect: rect) {
                drag = resize
            } else if let rect = selection, rect.contains(p) {
                drag = .move(offset: NSPoint(x: p.x - rect.minX, y: p.y - rect.minY))
            } else {
                drag = .new(start: p)
                controller.setSelection(nil)
            }
        case .window:
            controller.captureHoveredWindow()
        case .fullScreen:
            controller.captureScreen(screen)
        case .freeform:
            if let shape, shape.contains(p) {
                drag = .moveShape(last: p)
                NSCursor.closedHand.set()
            } else {
                controller.setShape(nil)
                let path = NSBezierPath()
                path.move(to: p)
                freeform = path
                needsDisplay = true
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller else { return }
        let p = clamp(convert(event.locationInWindow, from: nil))
        trace("dragged \(Int(p.x)),\(Int(p.y)) drag=\(String(describing: drag))")
        switch mode {
        case .rectangle:
            switch drag {
            case .new(let start):
                controller.setSelection((screen, NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                                                        width: abs(p.x - start.x), height: abs(p.y - start.y))))
            case .move(let offset):
                NSCursor.closedHand.set()
                guard let rect = selection else { return }
                var origin = NSPoint(x: p.x - offset.x, y: p.y - offset.y)
                origin.x = min(max(origin.x, 0), bounds.width - rect.width)
                origin.y = min(max(origin.y, 0), bounds.height - rect.height)
                controller.setSelection((screen, NSRect(origin: origin, size: rect.size)))
            case .resize(let fixed, let xEdge, let yEdge, let original):
                let x0 = xEdge ? min(fixed.x, p.x) : original.minX
                let x1 = xEdge ? max(fixed.x, p.x) : original.maxX
                let y0 = yEdge ? min(fixed.y, p.y) : original.minY
                let y1 = yEdge ? max(fixed.y, p.y) : original.maxY
                controller.setSelection((screen, NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)))
            case nil, .moveShape:
                break
            }
        case .freeform:
            if case .moveShape(let last) = drag, let shape {
                // Move by the pointer's travel, but keep the whole shape on this display.
                let b = shape.bounds
                let dx = min(max(p.x - last.x, -b.minX), bounds.width - b.maxX)
                let dy = min(max(p.y - last.y, -b.minY), bounds.height - b.maxY)
                let moved = shape.copy() as! NSBezierPath
                moved.transform(using: AffineTransform(translationByX: dx, byY: dy))
                controller.setShape((screen, moved))
                drag = .moveShape(last: NSPoint(x: last.x + dx, y: last.y + dy))
            } else {
                freeform?.line(to: p)
                needsDisplay = true
            }
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller else { return }
        trace("up drag=\(String(describing: drag))")
        switch mode {
        case .rectangle:
            if let rect = selection, rect.width < 4 || rect.height < 4 { controller.setSelection(nil) }
            drag = nil
            updateCursor(at: convert(event.locationInWindow, from: nil))
        case .freeform:
            if case .moveShape = drag {
                drag = nil
                updateCursor(at: convert(event.locationInWindow, from: nil))
                return
            }
            guard let path = freeform else { return }
            freeform = nil
            path.close()
            // Keep the shape on screen so it can be moved; Capture (or Return) takes it.
            if path.bounds.width >= 4, path.bounds.height >= 4 {
                controller.setShape((screen, path))
            } else {
                needsDisplay = true
            }
        default:
            break
        }
    }

    /// A drag that resizes the selection, if the press is on one of its corners or edges.
    private func resizeDrag(at p: NSPoint, rect: NSRect) -> Drag? {
        let grab: CGFloat = 8
        let nearL = abs(p.x - rect.minX) <= grab, nearR = abs(p.x - rect.maxX) <= grab
        let nearB = abs(p.y - rect.minY) <= grab, nearT = abs(p.y - rect.maxY) <= grab
        let insideX = p.x > rect.minX - grab && p.x < rect.maxX + grab
        let insideY = p.y > rect.minY - grab && p.y < rect.maxY + grab
        let xEdge = (nearL || nearR) && insideY
        let yEdge = (nearB || nearT) && insideX
        guard xEdge || yEdge else { return nil }
        let fixed = NSPoint(x: nearL ? rect.maxX : rect.minX, y: nearB ? rect.maxY : rect.minY)
        return .resize(fixed: fixed, xEdge: xEdge, yEdge: yEdge, original: rect)
    }

    /// An open hand over something that can be dragged to move it, otherwise a crosshair.
    private func updateCursor(at p: NSPoint) {
        let movable: Bool
        switch mode {
        case .rectangle:
            movable = selection.map { $0.contains(p) && resizeDrag(at: p, rect: $0) == nil } ?? false
        case .freeform:
            movable = shape?.contains(p) ?? false
        default:
            movable = false
        }
        (movable ? NSCursor.openHand : NSCursor.crosshair).set()
    }

    private func clamp(_ p: NSPoint) -> NSPoint {
        NSPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: controller?.cancel()              // Esc
        case 36, 76: controller?.captureNow()      // Return, Enter
        default: super.keyDown(with: event)
        }
    }

    func resetFreeform() {
        freeform = nil
        drag = nil
    }
}
