import AppKit
import Combine
import Sparkle

/// Runs Sparkle and exposes what the Settings window needs.
@MainActor
final class UpdaterModel: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    @Published var automaticallyChecks: Bool = true {
        didSet {
            if controller.updater.automaticallyChecksForUpdates != automaticallyChecks {
                controller.updater.automaticallyChecksForUpdates = automaticallyChecks
            }
        }
    }
    @Published private(set) var lastChecked: Date?

    private var controller: SPUStandardUpdaterController!
    private var observers: [NSKeyValueObservation] = []

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        let updater = controller.updater
        automaticallyChecks = updater.automaticallyChecksForUpdates
        lastChecked = updater.lastUpdateCheckDate
        observers = [
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] u, _ in
                let value = u.automaticallyChecksForUpdates
                Task { @MainActor in if self?.automaticallyChecks != value { self?.automaticallyChecks = value } }
            },
            updater.observe(\.lastUpdateCheckDate) { [weak self] u, _ in
                let date = u.lastUpdateCheckDate
                Task { @MainActor in self?.lastChecked = date }
            },
        ]
    }

    var canCheck: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        // Mac2Seven has no Dock icon, so bring it forward for Sparkle's window.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    /// Background (menu bar) apps should let Sparkle show scheduled update alerts gently.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        // A scheduled check found an update: bring the alert to the front so it isn't missed.
        if handleShowingUpdate && !state.userInitiated {
            Task { @MainActor in NSApp.activate() }
        }
    }
}
