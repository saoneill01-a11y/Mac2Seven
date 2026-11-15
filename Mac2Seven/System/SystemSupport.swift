import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A system-wide hotkey using the Carbon API (needs no Accessibility permission).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x4D325337), id: 1) // "M2S7"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// Borderless floating panel that can take keyboard focus without activating the app.
final class StartPanel: NSPanel {
    var onDismiss: (() -> Void)?

    init<Content: View>(size: NSSize, content: Content) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        contentView = host

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: self, queue: .main
        ) { [weak self] _ in
            self?.onDismiss?()
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum PowerAction: String, Codable, CaseIterable, Identifiable {
    case shutDown, restart, sleep, lock, logOut

    var id: String { rawValue }
    var title: String {
        switch self {
        case .shutDown: return "Shut down"
        case .restart: return "Restart"
        case .sleep: return "Sleep"
        case .lock: return "Lock"
        case .logOut: return "Log Out"
        }
    }
}

enum Power {
    static func run(_ action: PowerAction) {
        switch action {
        case .shutDown: appleScript("tell application \"System Events\" to shut down")
        case .restart: appleScript("tell application \"System Events\" to restart")
        case .logOut: appleScript("tell application \"System Events\" to log out")
        case .sleep: shell("/usr/bin/pmset", ["sleepnow"])
        case .lock: lockScreen()
        }
    }

    private static func appleScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Mac2Seven power action failed: \(error)") }
    }

    private static func shell(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try? p.run()
    }

    /// Uses the same private call as the Lock Screen menu item, falling back to sleeping the display.
    private static func lockScreen() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let sym = dlsym(handle, "SACLockScreenImmediate") {
            typealias LockFn = @convention(c) () -> Int32
            _ = unsafeBitCast(sym, to: LockFn.self)()
            return
        }
        shell("/usr/bin/pmset", ["displaysleepnow"])
    }
}
