import AppKit
import SpotlightKit

/// App search (part of default search) and the All Apps list sorted by recently opened / recently added.
final class AppsExtension: Extension {
    struct App {
        let name: String
        let url: URL
        let bundleID: String?
        var lastUsed: Date?
        let added: Date?
    }

    private var apps: [App] = []
    private var indexedAt = Date.distantPast
    /// Launches made through My Spotlight, which macOS may not have reflected in Spotlight metadata yet.
    private var launches: [String: Date] = [:]

    override var manifest: Manifest {
        Manifest(id: "apps", title: "All Apps", subtitle: "Recently opened or recently added applications", icon: .symbol("square.grid.2x2"))
    }

    override var triggers: [Trigger] { [.defaultSearch, .command("apps")] }

    override func activate(context: ExtensionContext) async {
        launches = context.storage(.persistent).value([String: Date].self, forKey: "launches") ?? [:]
        await reindex()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let url = app.bundleURL else { return }
            MainActor.assumeIsolated { self?.touch(url) }
        }
    }

    override func rootView() -> ListView? {
        ListView(title: manifest.title, icon: manifest.icon, placeholder: "Filter apps…",
                 filters: ["Recently Opened", "Recently Added", "A–Z"]) { [unowned self] q in try await self.search(q) }
    }

    override func search(_ query: Query) async throws -> [Section] {
        if Date().timeIntervalSince(indexedAt) > 120 { Task { await reindex() } }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })

        if query.mode == .default {
            guard !query.isEmpty else { return [] }
            let scored = apps.compactMap { app -> (Int, App)? in
                guard var s = Fuzzy.score(query.text, [app.name, app.bundleID?.components(separatedBy: ".").last ?? ""]) else { return nil }
                // Recency nudges ties: up to +60 for apps used today.
                if let used = app.lastUsed { s += max(0, 60 - Int(Date().timeIntervalSince(used) / 3600)) }
                return (s, app)
            }
            let top = scored.sorted { $0.0 > $1.0 }.prefix(8).map { item($0.1, running: running, detail: nil) }
            return [Section("Applications", Array(top))]
        }

        var list = apps.filter { Fuzzy.score(query.text, $0.name) != nil }
        switch query.filter {
        case "Recently Added":
            list.sort { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
            return [Section("Recently Added", list.map { item($0, running: running, detail: $0.added.map { "added \($0.relative)" }) })]
        case "A–Z":
            list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return [Section("A–Z", list.map { item($0, running: running, detail: nil) })]
        default:
            list.sort { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
            return [Section("Recently Opened", list.map { item($0, running: running, detail: $0.lastUsed.map { "opened \($0.relative)" }) })]
        }
    }

    private func item(_ app: App, running: Set<String>, detail: String?) -> Item {
        let path = app.url.path
        let isRunning = running.contains(app.url.standardizedFileURL.path)
        let folder = app.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return Item(
            id: path, title: app.name,
            subtitle: ["Application", detail ?? folder].joined(separator: " · "),
            icon: .file(path),
            accessories: isRunning ? [.pill("Running", .green)] : [],
            primary: Action("Open App", icon: .symbol("arrow.up.forward.app")) { [weak self] in
                NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
                self?.touch(app.url)
                return .close
            },
            secondary: Action("Show in Finder", icon: .symbol("folder")) {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
                return .close
            },
            more: [
                Action("Copy Path", icon: .symbol("doc.on.doc"), shortcut: Shortcut("c", [.command, .shift])) { [weak self] in
                    self?.context.copy(path)
                    return .hud("Path copied")
                },
                Action("Quit App", icon: .symbol("xmark.circle"), shortcut: Shortcut("q", [.command, .option]), destructive: true) {
                    NSWorkspace.shared.runningApplications.filter { $0.bundleURL == app.url }.forEach { $0.terminate() }
                    return .stay
                },
            ])
    }

    private func touch(_ url: URL) {
        launches[url.path] = Date()
        if let i = apps.firstIndex(where: { $0.url.path == url.path }) { apps[i].lastUsed = Date() }
        context.storage(.persistent).set(launches, forKey: "launches")
    }

    private func reindex() async {
        indexedAt = Date()
        let launches = self.launches
        apps = await Task.detached(priority: .utility) { AppsExtension.scan(launches: launches) }.value
    }

    nonisolated private static func scan(launches: [String: Date]) -> [App] {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     "/Applications/Utilities", NSHomeDirectory() + "/Applications", "/System/Library/CoreServices/Applications"]
        var seen = Set<String>()
        var out: [App] = []

        func visit(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names where !name.hasPrefix(".") {
                let path = (dir as NSString).appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    guard seen.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path).inserted else { continue }
                    let url = URL(fileURLWithPath: path)
                    let md = MDItemCreateWithURL(nil, url as CFURL)
                    let used = md.flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
                    let added = md.flatMap { MDItemCopyAttribute($0, kMDItemDateAdded) as? Date }
                        ?? (try? fm.attributesOfItem(atPath: path)[.creationDate] as? Date)
                    let mine = launches[path]
                    out.append(App(name: fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""),
                                   url: url, bundleID: Bundle(url: url)?.bundleIdentifier,
                                   lastUsed: [used, mine].compactMap { $0 }.max(), added: added))
                } else if depth < 2 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { visit(path, depth: depth + 1) }
                }
            }
        }
        roots.forEach { visit($0, depth: 0) }
        return out
    }
}
