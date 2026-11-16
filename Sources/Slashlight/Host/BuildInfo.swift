import AppKit

/// Which build this is. `scripts/build-app.sh` writes the channel, build number and commit into Info.plist;
/// a bare binary from `swift run` counts as a local build.
enum BuildInfo {
    enum Channel: String {
        case local, pr, test, beta, stable
    }

    private static let info = Bundle.main.infoDictionary ?? [:]

    static let channel: Channel = Bundle.main.bundleURL.pathExtension == "app"
        ? (info["SlashlightChannel"] as? String).flatMap(Channel.init(rawValue:)) ?? .stable
        : .local

    /// "Slashlight", "Slashlight Test" or "Slashlight Dev".
    static let name: String = info["CFBundleName"] as? String ?? "Slashlight Dev"
    static let version: String = (info["CFBundleShortVersionString"] as? String) ?? "dev"
    /// One more for every pull request merged into test; beta and stable keep the number of the test build they came from.
    static let buildNumber: String = (info["CFBundleVersion"] as? String) ?? "0"
    static let commit: String = (info["SlashlightCommit"] as? String) ?? ""
    static let pullRequest: String = (info["SlashlightPullRequest"] as? String) ?? ""

    /// Local, pull request and test builds: shown in the Dock and tagged in the panel so you always know which one runs.
    static var isPreview: Bool { channel == .local || channel == .pr || channel == .test }

    /// The tag in the panel's footer; nil for stable releases.
    static var tag: String? {
        switch channel {
        case .local: return commit.isEmpty ? "Local build" : "Local build · \(commit)"
        case .pr: return pullRequest.isEmpty ? "PR build \(buildNumber)" : "PR #\(pullRequest) · on test \(buildNumber)"
        case .test: return "Test · build \(buildNumber)"
        case .beta: return "Beta · build \(buildNumber)"
        case .stable: return nil
        }
    }

    /// The Dock badge of preview builds.
    static var badge: String? {
        switch channel {
        case .local: return "DEV"
        case .pr: return "PR"
        case .test: return "TEST \(buildNumber)"
        case .beta, .stable: return nil
        }
    }

    /// "0.3.0 (build 24)", plus the channel and commit where they help.
    static var fullVersion: String {
        var s = "\(version) (build \(buildNumber))"
        if channel != .stable { s += " · \(channel.rawValue)" }
        if !commit.isEmpty, channel != .stable, channel != .beta { s += " · \(commit)" }
        return s
    }
}
