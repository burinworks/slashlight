import Foundation

/// The Seatbelt profile an extension or script runs under (`/usr/bin/sandbox-exec -p`). Children inherit it, so
/// a script cannot hand its work to a program that escapes.
///
/// The profile starts from "allow" so system libraries, fonts and frameworks keep working, then takes away
/// everything that could reach your data or act for you:
/// - the home folder and the per-user temp folders (`/var/folders/…`), except the folders listed below;
/// - writing anywhere outside those folders, `/dev` and `/tmp` (so it can't change Homebrew's programs, say);
/// - the network, unless `network` is granted;
/// - starting other programs, unless `subprocesses` is granted (exec of the extension's own program still works);
/// - the clipboard, the Keychain, Apple Events (`osascript` driving other apps), new launchd jobs, and Launch
///   Services (`open`), unless `open` is granted. An app opened that way runs outside the sandbox.
struct Sandbox {
    var permissions: ExtensionPermissions
    /// The extension's folder: read and write.
    var ownFolder: URL?
    /// A script's folder: read only, so it can read itself and files next to it.
    var scriptFolder: URL?
    /// `ExtensionData/<id>`: read and write.
    var dataFolder: URL
    /// This extension's `TMPDIR`: read and write.
    var tempFolder: URL

    static let executable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    /// Folders macOS guards with its own privacy prompt. A program that is its own responsible process can create
    /// files there but not read them, and it can't ask for access, so a script working in ~/Documents fails.
    static let privacyFolders = ["Documents", "Desktop", "Downloads"]

    /// Whether this extension was granted a folder that only Slashlight can be allowed into. It then runs under
    /// Slashlight's responsibility (macOS asks "Slashlight would like to access…" the first time) and the profile
    /// alone keeps it from Accessibility and Screen Recording; everything else runs as its own responsible process
    /// too, so both protections apply.
    var needsSlashlightsFolderAccess: Bool {
        let home = ExtensionPermissions.home.path
        return (permissions.read + permissions.write).contains { url in
            Self.privacyFolders.contains { url.path == home + "/" + $0 || url.path.hasPrefix(home + "/" + $0 + "/") }
        }
    }

    /// Folders under the per-user temp area are shared by every app the user runs: Slashlight's caches,
    /// other apps' downloads. `getconf DARWIN_USER_DIR`, i.e. the parent of `T/` and `C/`.
    static var userDarwinFolder: URL {
        URL(fileURLWithPath: realPath(NSTemporaryDirectory())).deletingLastPathComponent()
    }

    /// The kernel checks real paths (`/private/var/…`); `URL.resolvingSymlinksInPath` drops the `/private`.
    /// A path that doesn't exist yet keeps its real parent.
    static func realPath(_ path: String) -> String {
        if let r = realpath(path, nil) {
            defer { free(r) }
            return String(cString: r)
        }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        guard parent != path, parent != "/" else { return path }
        return (realPath(parent) as NSString).appendingPathComponent(url.lastPathComponent)
    }

    var profile: String {
        func path(_ url: URL) -> String { Self.quote(Self.realPath(url.path)) }
        func subpaths(_ urls: [URL]) -> String { urls.map { "(subpath \(path($0)))" }.joined(separator: " ") }
        let home = ExtensionPermissions.home
        var p = [
            "(version 1)",
            "(allow default)",
            // Nothing in the home folder or the shared temp area, except what follows. stat() still works, so
            // shells can cd and check paths; listing and reading don't.
            "(deny file-read-data file-write* (subpath \(path(home))) (subpath \(path(Self.userDarwinFolder))))",
            "(deny file-write* (subpath \"/\"))",
            "(allow file-write* (subpath \"/dev\") (subpath \"/private/tmp\") (subpath \"/private/var/tmp\"))",
        ]
        let readable = permissions.read + permissions.write
        if !readable.isEmpty { p.append("(allow file-read-data \(subpaths(readable)))") }
        if !permissions.write.isEmpty { p.append("(allow file-write* \(subpaths(permissions.write)))") }
        // Granted folders never reach these, even when they contain them (~/.config grants ~/.config/gh otherwise).
        let never = ExtensionPermissions.neverAllowed.map { home.appendingPathComponent($0) }
        p.append("(deny file-read-data file-write* \(subpaths(never)))")
        // Last, so they win over the Library rule above.
        let own = [ownFolder, dataFolder, tempFolder].compactMap { $0 }
        p.append("(allow file-read-data file-write* \(subpaths(own)))")
        if let scriptFolder { p.append("(allow file-read-data (subpath \(path(scriptFolder))))") }

        if permissions.network == .none { p.append("(deny network*)") }
        if !permissions.subprocesses { p.append("(deny process-fork)") }
        // Clipboard, Keychain, Apple Events, and every way to use Slashlight's own privacy grants: Accessibility
        // (axserver), and the window server, which screenshots, the window list and synthetic keystrokes go through.
        let services = ["com.apple.pasteboard.1", "com.apple.SecurityServer", "com.apple.securityd.xpc",
                        "com.apple.coreservices.appleevents", "com.apple.windowserver.active", "com.apple.windowserver",
                        "com.apple.tccd", "com.apple.replayd"]
        p.append("(deny mach-lookup " + services.map { "(global-name \(Self.quote($0)))" }.joined(separator: " ")
                 + " (global-name-regex #\"^com\\.apple\\.screencapture\") (local-name \"com.apple.axserver\"))")
        p.append("(deny device-camera)")
        p.append("(deny device-microphone)")
        // Launching apps, files and URLs through Launch Services (`open`, NSWorkspace). Revealing in Finder still works.
        if !permissions.open { p.append("(deny lsopen)") }
        p.append("(deny appleevent-send)")
        p.append("(deny job-creation)")
        return p.joined(separator: "\n")
    }

    /// SBPL string literal.
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Creates the data and temp folders, so the extension can use them straight away.
    func prepare() {
        for url in [dataFolder, tempFolder] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// `ExtensionData/<id>` and a temp folder of its own. Script ids look like `scripts/<name>`.
    static func folders(extensionID id: String) -> (data: URL, temp: URL) {
        let safe = id.replacingOccurrences(of: "/", with: "-")
        return (Paths.support.appendingPathComponent("ExtensionData", isDirectory: true).appendingPathComponent(safe, isDirectory: true),
                URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    .appendingPathComponent("Slashlight Extensions", isDirectory: true).appendingPathComponent(safe, isDirectory: true))
    }
}
