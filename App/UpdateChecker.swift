import AppKit
import Sparkle

/// In-place updates with Sparkle: it reads the appcast on GitHub (SUFeedURL in Info.plist), downloads the newer
/// notarized zip, checks its EdDSA signature and replaces the app. The window, the daily check and the
/// automatic-update choice are Sparkle's.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    /// The Settings toggle; Sparkle keeps it in the app's defaults.
    var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Starts Sparkle's scheduled checks. Debug builds skip them so working on Dottie does not keep asking.
    func start() {
        #if !DEBUG
        controller.startUpdater()
        #endif
    }

    /// Check for Updates…: Sparkle also says when Dottie is up to date or the check failed.
    func checkForUpdates() {
        #if DEBUG
        Alerts.show("Updates are off in debug builds", "Sparkle only runs in Release builds.")
        #else
        controller.checkForUpdates(nil)
        #endif
    }
}
