import AppKit
import SpotlightKit

/// File search through the Spotlight index (`NSMetadataQuery`), part of default search.
final class FilesExtension: Extension {
    override var manifest: Manifest {
        Manifest(id: "files", title: "Files", subtitle: "Search files in your home folder", icon: .symbol("doc.text.magnifyingglass"))
    }

    override var triggers: [Trigger] { [.defaultSearch, .command("files")] }

    override func rootView() -> ListView? {
        ListView(title: manifest.title, icon: manifest.icon, placeholder: "Search files…",
                 filters: ["All", "Folders", "Documents", "Images", "Code"]) { [unowned self] q in try await self.search(q) }
    }

    override func search(_ query: Query) async throws -> [Section] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return [] }
        try await Task.sleep(nanoseconds: 120_000_000) // debounce; throws if a newer keystroke cancelled us

        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
        var predicates = [
            NSPredicate(format: "kMDItemFSName LIKE[cd] %@", "*\(escaped)*"),
            NSPredicate(format: "kMDItemContentTypeTree != 'com.apple.application-bundle'"),
        ]
        if let type = Self.contentTypes[query.filter ?? ""] {
            predicates.append(NSPredicate(format: "kMDItemContentTypeTree == %@", type))
        }
        let limit = query.mode == .scoped ? 60 : 8
        let found = await MetadataSearch.run(NSCompoundPredicate(andPredicateWithSubpredicates: predicates), limit: limit * 8)
        try Task.checkCancellation()
        // Drop dependency and cache folders, then put name matches that start with the query first.
        let urls = found
            .filter { url in !Self.noise.contains { url.path.contains($0) } }
            .enumerated()
            .map { (offset, url) in ((Fuzzy.score(text, url.deletingPathExtension().lastPathComponent) ?? 0) - offset, url) }
            .sorted { $0.0 > $1.0 }
            .prefix(limit)
            .map(\.1)
        return [Section("Files", urls.map(item))]
    }

    private static let noise = ["/node_modules/", "/Library/", "/.git/", "/.build/", "/build/", "/DerivedData/", "/.Trash/", "/vendor/", "/Pods/", "/."]

    private static let contentTypes = [
        "Folders": "public.folder", "Documents": "public.content", "Images": "public.image", "Code": "public.source-code",
    ]

    private func item(_ url: URL) -> Item {
        let path = url.path
        let parent = url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return Item(
            id: path, title: url.lastPathComponent, subtitle: parent, icon: .file(path),
            primary: Action("Open", icon: .symbol("arrow.up.forward.square")) {
                NSWorkspace.shared.open(url)
                return .close
            },
            secondary: Action("Show in Finder", icon: .symbol("folder")) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return .close
            },
            more: [
                Action("Copy Path", icon: .symbol("doc.on.doc"), shortcut: Shortcut("c", [.command, .shift])) { [weak self] in
                    self?.context.copy(path)
                    return .hud("Path copied")
                },
                Action("Copy File", icon: .symbol("doc.on.clipboard"), shortcut: Shortcut("c", [.command, .option])) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([url as NSURL])
                    return .hud("File copied")
                },
                Action("Open in Terminal", icon: .symbol("terminal"), shortcut: Shortcut("t", [.command])) {
                    let dir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
                    NSWorkspace.shared.open([dir], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                            configuration: NSWorkspace.OpenConfiguration())
                    return .close
                },
                Action("Move to Trash", icon: .symbol("trash"), shortcut: Shortcut("delete", [.command]), destructive: true) {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    return .stay
                },
            ])
    }
}

@MainActor
enum MetadataSearch {
    /// One-shot Spotlight query over the home folder, most recently used first.
    static func run(_ predicate: NSPredicate, limit: Int) async -> [URL] {
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        return await withCheckedContinuation { cont in
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { _ in
                query.disableUpdates()
                query.stop()
                var urls: [URL] = []
                for i in 0..<min(query.resultCount, limit) {
                    if let item = query.result(at: i) as? NSMetadataItem,
                       let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                        urls.append(URL(fileURLWithPath: path))
                    }
                }
                if let token { NotificationCenter.default.removeObserver(token) }
                cont.resume(returning: urls)
            }
            if !query.start() {
                if let token { NotificationCenter.default.removeObserver(token) }
                cont.resume(returning: [])
            }
        }
    }
}
