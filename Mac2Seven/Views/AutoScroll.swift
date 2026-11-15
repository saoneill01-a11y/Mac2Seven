import AppKit
import SwiftUI

/// Scrolls the visible list while something is being dragged near (or past) its top or bottom edge.
/// SwiftUI doesn't do this on the Mac, so it watches the mouse and nudges the underlying NSScrollView.
@MainActor
final class AutoScroller {
    /// The list currently on screen; set by `ScrollViewHook`.
    weak var scrollView: NSScrollView?

    private var timer: Timer?
    /// Distance inside each edge where scrolling starts.
    private let zone: CGFloat = 44
    /// Points per frame at the edge; grows (up to `maxBoost`×) the further the mouse goes past it.
    private let baseSpeed: CGFloat = 6
    private let maxBoost: CGFloat = 2.2

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes so it keeps firing while the drag is tracking the mouse.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let scrollView, let window = scrollView.window, window.isVisible,
              let document = scrollView.documentView else { return }

        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = scrollView.convert(inWindow, from: nil)
        let bounds = scrollView.bounds

        // Only while the pointer is over the list's column, not the right-hand side of the menu.
        guard point.x >= bounds.minX - 20, point.x <= bounds.maxX + 20 else { return }

        let fromTop = scrollView.isFlipped ? point.y - bounds.minY : bounds.maxY - point.y
        let height = bounds.height

        var speed: CGFloat = 0
        if fromTop < zone {
            speed = -baseSpeed * min((zone - fromTop) / zone, maxBoost)
        } else if fromTop > height - zone {
            speed = baseSpeed * min((fromTop - (height - zone)) / zone, maxBoost)
        }
        guard speed != 0 else { return }

        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        let maxOffset = max(0, document.frame.height - clip.bounds.height)
        // In a flipped document, a larger y is further down the list.
        origin.y += document.isFlipped ? speed : -speed
        origin.y = min(max(origin.y, 0), maxOffset)
        guard origin.y != clip.bounds.origin.y else { return }

        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }
}

/// Put in the background of a ScrollView's content to tell the auto-scroller which NSScrollView to drive.
struct ScrollViewHook: NSViewRepresentable {
    let scroller: AutoScroller

    func makeNSView(context: Context) -> HookView {
        let view = HookView()
        view.scroller = scroller
        return view
    }

    func updateNSView(_ view: HookView, context: Context) {
        view.scroller = scroller
    }

    final class HookView: NSView {
        weak var scroller: AutoScroller?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.enclosingScrollView else { return }
                self.scroller?.scrollView = scrollView
            }
        }
    }
}
