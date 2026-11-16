import Foundation

/// A self-contained run of the app for automated checks (`scripts/dev-suite.sh`), started with
/// `SLASHLIGHT_ISOLATED_HOME=<folder>`. It touches nothing of the user's:
/// - settings, history, extensions, usage and search memory live under `<folder>` instead of Application Support;
/// - the clipboard history key is made in memory, so the Keychain is never read (no password prompt);
/// - no global hotkeys, menu bar icon, Dock icon, update checks or welcome tour.
enum DevSuite {
    static let home: URL? = ProcessInfo.processInfo.environment["SLASHLIGHT_ISOLATED_HOME"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

    static var isActive: Bool { home != nil }

    /// Settings a fresh dev-suite home starts with: no tour, and no file search, so results never come from the
    /// user's disk and are the same on every Mac.
    static func initialSettings() -> Settings {
        var s = Settings()
        s.onboardingCompleted = true
        s.disabledExtensions = ["files"]
        return s
    }
}
