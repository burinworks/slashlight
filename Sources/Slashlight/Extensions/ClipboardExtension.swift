import AppKit
import SlashlightKit

/// Clipboard history: text, links, images and files, with every format the source app offered, so copying an
/// entry back keeps its formatting. Saved encrypted between launches (Settings → General → Clipboard History).
/// ↵ copies the entry and moves it to the top; ⌘↵ pastes it into the frontmost app.
final class ClipboardExtension: Extension {
    static weak var shared: ClipboardExtension?

    private var entries: [ClipEntry] = []
    private var changeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var vault: ClipboardVault?
    private var thumbnails: [UUID: NSImage] = [:]
    private weak var root: ListView?
    private let limit = 300
    /// Disk and memory budget; the oldest entries go first.
    private let byteBudget = 500 * 1024 * 1024

    override var manifest: Manifest {
        Manifest(id: "clipboard", title: "Clipboard History", subtitle: "Text, images and files you copied", icon: .symbol("doc.on.clipboard"))
    }

    override var triggers: [Trigger] { [.command("clipboard")] }

    override func activate(context: ExtensionContext) async {
        Self.shared = self
        apply(Host.shared.settings)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    override func deactivate() async { timer?.invalidate() }

    override func panelWillOpen() { forgetExpired() }

    /// Called at launch and whenever settings change.
    func apply(_ settings: Settings) {
        if settings.clipboardKeepHistory {
            if vault == nil, let key = ClipboardVault.keychainKey() {
                let v = ClipboardVault(directory: context.supportDirectory.appendingPathComponent(ClipboardVault.folder, isDirectory: true), key: key)
                vault = v
                // Entries copied before the saved ones finished loading stay on top.
                let saved = v.loadAll().filter { s in !entries.contains { $0.fingerprint == s.fingerprint } }
                let unsaved = entries
                entries = (entries + saved).sorted { $0.date > $1.date }
                unsaved.forEach { v.save($0) }
                trim()
            }
        } else if let v = vault {
            v.deleteAll()
            vault = nil
        }
        forgetExpired()
        context.refresh()
    }

    func clearAll() {
        entries.removeAll()
        thumbnails.removeAll()
        vault?.deleteAll()
        context.refresh()
    }

    // MARK: Recording

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        changeCount = pb.changeCount
        guard var entry = ClipboardCapture.capture(pb, source: NSWorkspace.shared.frontmostApplication?.localizedName) else { return }
        if let i = entries.firstIndex(where: { $0.fingerprint == entry.fingerprint }) {
            let old = entries.remove(at: i)
            entry.source = old.source ?? entry.source
            vault?.delete([old.id])
            thumbnails[old.id] = nil
        }
        entries.insert(entry, at: 0)
        vault?.save(entry)
        trim()
        context.refresh()
    }

    private func trim() {
        var bytes = 0
        var keep = 0
        for e in entries {
            bytes += e.byteCount
            if keep >= limit || (keep > 0 && bytes > byteBudget) { break }
            keep += 1
        }
        guard keep < entries.count else { return }
        let dropped = entries[keep...].map(\.id)
        entries.removeLast(entries.count - keep)
        dropped.forEach { thumbnails[$0] = nil }
        vault?.delete(dropped)
    }

    private func forgetExpired() {
        let days = Host.shared.settings.clipboardForgetAfterDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let old = entries.filter { $0.date < cutoff }.map(\.id)
        guard !old.isEmpty else { return }
        entries.removeAll { $0.date < cutoff }
        old.forEach { thumbnails[$0] = nil }
        vault?.delete(old)
    }

    // MARK: Screen

    static let filters = ["All", "Text", "Images", "Files", "Links"]

    override func rootView() -> ListView? {
        let view = ListView(title: manifest.title, icon: manifest.icon, placeholder: "Search clipboard history…",
                            filters: Self.filters) { [unowned self] q in try await self.search(q) }
        root = view
        return view
    }

    override func search(_ query: Query) async throws -> [Section] {
        // Images read best as large tiles.
        root?.layout = query.filter == "Images" ? .grid(columns: 4) : .list
        let list = entries.filter { e in
            switch query.filter {
            case "Text": guard e.kind == .text else { return false }
            case "Images": guard e.kind == .image else { return false }
            case "Files": guard e.kind == .files else { return false }
            case "Links": guard e.kind == .link else { return false }
            default: break
            }
            return query.isEmpty || e.text.localizedCaseInsensitiveContains(query.text)
                || (e.source ?? "").localizedCaseInsensitiveContains(query.text) || Fuzzy.score(query.text, e.text) != nil
        }
        if list.isEmpty && query.isEmpty {
            let what = ["Images": "No images yet", "Files": "No files yet", "Links": "No links yet"][query.filter ?? ""] ?? "Nothing copied yet"
            return [Section("Clipboard", [Item(id: "empty", title: what, subtitle: "Copy something and it shows up here",
                                               icon: .symbol("tray"), primary: Action("Close") { .close })])]
        }
        return [Section(query.filter.flatMap { $0 == "All" ? nil : $0 } ?? "History", list.map(item))]
    }

    private func item(_ e: ClipEntry) -> Item {
        let firstLine = e.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? e.text
        var meta = [e.source, e.date.relative].compactMap { $0 }
        let title: String
        let icon: Icon
        switch e.kind {
        case .text, .link:
            let lines = e.text.split(whereSeparator: \.isNewline).count
            meta.append(lines > 1 ? "\(lines) lines" : "\(e.text.count) chars")
            if e.items.contains(where: { $0["public.rtf"] != nil || $0["public.html"] != nil }) { meta.append("formatted") }
            title = String(firstLine.trimmingCharacters(in: .whitespaces).prefix(90))
            icon = .symbol(e.kind == .link ? "link" : lines > 1 ? "text.alignleft" : "text.quote")
        case .image:
            title = e.pixels.map { "Image \($0[0])×\($0[1])" } ?? "Image"
            meta.insert(ByteCountFormatter.string(fromByteCount: Int64(e.imageData?.count ?? 0), countStyle: .file), at: 0)
            icon = thumbnail(e).map(Icon.image) ?? .symbol("photo")
        case .files:
            let urls = e.fileURLs
            title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files: " + urls.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
            meta.insert(urls.first?.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "", at: 0)
            icon = urls.count == 1 && Self.isImageFile(urls[0]) ? (thumbnail(e).map(Icon.image) ?? .file(urls[0].path)) : .file(urls.first?.path ?? "/")
        }

        var more: [Action] = []
        switch e.kind {
        case .text, .link:
            more.append(Action("Paste as Plain Text", icon: .symbol("textformat"), shortcut: Shortcut("v", [.command, .shift])) { [weak self] in
                self?.promote(e.id, restore: false)
                return .paste(e.text)
            })
            more.append(Action("Save as Snippet", icon: .symbol("text.badge.plus"), shortcut: Shortcut("s", [.command])) {
                SnippetsExtension.shared?.add(name: String(firstLine.prefix(40)), text: e.text)
                return .hud("Saved to Snippets")
            })
        case .image:
            more.append(Action("Open in Preview", icon: .symbol("eye"), shortcut: Shortcut("o", [.command])) {
                guard let data = e.imageData else { return .stay }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard \(e.id.uuidString.prefix(8)).png")
                let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
                try png.write(to: url)
                NSWorkspace.shared.open(url)
                return .close
            })
        case .files:
            more.append(Action("Open", icon: .symbol("arrow.up.forward.app"), shortcut: Shortcut("o", [.command])) {
                e.fileURLs.forEach { NSWorkspace.shared.open($0) }
                return .close
            })
            more.append(Action("Show in Finder", icon: .symbol("folder"), shortcut: Shortcut("f", [.command, .shift])) {
                NSWorkspace.shared.activateFileViewerSelecting(e.fileURLs)
                return .close
            })
        }
        more.append(Action("Delete", icon: .symbol("trash"), shortcut: Shortcut("delete", [.command]), destructive: true) { [weak self] in
            self?.entries.removeAll { $0.id == e.id }
            self?.vault?.delete([e.id])
            return .stay
        })
        more.append(Action("Clear History", icon: .symbol("trash.slash"), shortcut: Shortcut("delete", [.command, .shift]), destructive: true) { [weak self] in
            self?.clearAll()
            return .stay
        })

        return Item(
            id: e.id.uuidString,
            title: title,
            subtitle: meta.filter { !$0.isEmpty }.joined(separator: " · "),
            icon: icon,
            primary: Action("Copy", icon: .symbol("doc.on.doc")) { [weak self] in
                self?.promote(e.id)
                return .hud("Copied")
            },
            secondary: Action("Paste", icon: .symbol("arrow.down.doc")) { [weak self] in
                self?.promote(e.id)
                Host.shared.pasteClipboard()
                return .close
            },
            more: more)
    }

    /// Moves the entry to the top and, unless `restore` is false, puts all of its formats on the clipboard.
    private func promote(_ id: UUID, restore: Bool = true) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        var e = entries.remove(at: i)
        e.date = Date()
        entries.insert(e, at: 0)
        vault?.save(e)
        guard restore else { return }
        ClipboardCapture.restore(e, to: .general)
        changeCount = NSPasteboard.general.changeCount
    }

    // MARK: Thumbnails

    private func thumbnail(_ e: ClipEntry) -> NSImage? {
        if let t = thumbnails[e.id] { return t }
        let source: NSImage?
        if let data = e.imageData { source = NSImage(data: data) } else { source = e.fileURLs.first.flatMap { NSImage(contentsOf: $0) } }
        guard let image = source, image.size.width > 0, image.size.height > 0 else { return nil }
        let side: CGFloat = 256
        let scale = min(1, side / max(image.size.width, image.size.height))
        let size = NSSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let small = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        thumbnails[e.id] = small
        return small
    }

    private static func isImageFile(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "webp", "bmp"].contains(url.pathExtension.lowercased())
    }
}
