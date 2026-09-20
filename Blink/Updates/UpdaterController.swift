import Sparkle

/// Owns the one Sparkle updater for the app's lifetime. Blink has no SwiftUI
/// `Commands`, so the menu bar asks this directly rather than observing it.
@MainActor
final class UpdaterController {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: Self.shouldStart,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Only Release builds check the feed: a Debug build would offer to replace
    /// itself with the published release, and tests must never touch the network.
    private static var shouldStart: Bool {
        #if DEBUG
        false
        #else
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #endif
    }
}
