import AppKit
import Sparkle

/// In-app updates through Sparkle. The feed (`SUFeedURL`) and the EdDSA public key (`SUPublicEDKey`) come from
/// Info.plist, which `scripts/build-app.sh` writes. Builds without a key (local and debug builds) never check.
///
/// One appcast serves both channels: stable items have no channel, beta items carry `<sparkle:channel>beta`.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?
    private var beta = false

    /// Whether this build can update itself.
    var isAvailable: Bool { controller != nil }

    func start(with settings: Settings) {
        guard controller == nil, Bundle.main.bundleURL.pathExtension == "app",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty else { return }
        beta = settings.betaUpdates
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        apply(settings)
    }

    /// Mirrors the update toggles from `Settings` into Sparkle.
    func apply(_ settings: Settings) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = settings.autoInstallUpdates
        if settings.betaUpdates != beta {
            beta = settings.betaUpdates
            // Look again soon so joining the beta offers the latest beta right away.
            updater.resetUpdateCycleAfterShortDelay()
        }
    }

    @objc func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        beta ? ["beta"] : []
    }

    // MARK: SPUStandardUserDriverDelegate

    // Slashlight is a menu bar agent, so a scheduled update alert would otherwise open behind other windows.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if handleShowingUpdate { NSApp.activate(ignoringOtherApps: true) }
    }
}
