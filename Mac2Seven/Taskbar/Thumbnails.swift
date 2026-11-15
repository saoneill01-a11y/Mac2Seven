import AppKit
import ScreenCaptureKit

/// Window preview images for the taskbar, captured with ScreenCaptureKit (needs Screen Recording permission).
/// Minimized windows can't be captured, so the last image taken while the window was visible is kept.
@MainActor
final class Thumbnails: ObservableObject {
    @Published private(set) var images: [CGWindowID: NSImage] = [:]
    @Published private(set) var hasPermission = CGPreflightScreenCaptureAccess()

    func checkPermission() { hasPermission = CGPreflightScreenCaptureAccess() }

    /// Asks macOS for Screen Recording access (shows the system prompt the first time).
    func requestPermission() {
        hasPermission = CGRequestScreenCaptureAccess()
    }

    /// Captures fresh images for the visible windows in the list.
    func capture(_ windows: [TaskWindow]) {
        checkPermission()
        guard hasPermission else { return }
        let wanted = Set(windows.filter { !$0.minimized }.map(\.id))
        guard !wanted.isEmpty else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            for window in content.windows where wanted.contains(window.windowID) {
                let config = SCStreamConfiguration()
                let scale: CGFloat = 2
                let maxSide: CGFloat = 240
                let ratio = min(maxSide / max(window.frame.width, 1), maxSide / max(window.frame.height, 1), 1)
                config.width = max(Int(window.frame.width * ratio * scale), 2)
                config.height = max(Int(window.frame.height * ratio * scale), 2)
                config.showsCursor = false
                let filter = SCContentFilter(desktopIndependentWindow: window)
                if let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    images[window.windowID] = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
                }
            }
        }
    }

    /// Drops images of windows that no longer exist.
    func prune(keeping ids: Set<CGWindowID>) {
        let stale = images.keys.filter { !ids.contains($0) }
        if !stale.isEmpty { stale.forEach { images[$0] = nil } }
    }
}
