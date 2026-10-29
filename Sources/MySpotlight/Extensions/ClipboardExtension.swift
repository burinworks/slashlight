import AppKit
import SpotlightKit

/// Text clipboard history, kept in memory only (lost on quit, by design).
/// ↵ copies the entry and moves it to the top; ⌘↵ pastes it into the frontmost app.
final class ClipboardExtension: Extension {
    struct Entry {
        let id = UUID()
        var text: String
        var date: Date
        var source: String?
    }

    private var entries: [Entry] = []
    private var changeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private let limit = 300

    override var manifest: Manifest {
        Manifest(id: "clipboard", title: "Clipboard History", subtitle: "Everything you copied this session", icon: .symbol("doc.on.clipboard"))
    }

    override var triggers: [Trigger] { [.command("clipboard")] }

    override func activate(context: ExtensionContext) async {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    override func deactivate() async { timer?.invalidate() }

    override func rootView() -> ListView? {
        ListView(title: manifest.title, icon: manifest.icon, placeholder: "Search clipboard history…",
                 filters: ["All", "Text", "Links"]) { [unowned self] q in try await self.search(q) }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        changeCount = pb.changeCount
        let types = pb.types ?? []
        // Respect password managers (nspasteboard.org conventions).
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) ||
            types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) { return }
        guard let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var source = NSWorkspace.shared.frontmostApplication?.localizedName
        if let i = entries.firstIndex(where: { $0.text == text }) { source = entries.remove(at: i).source ?? source }
        entries.insert(Entry(text: text, date: Date(), source: source), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        context.refresh()
    }

    override func search(_ query: Query) async throws -> [Section] {
        let list = entries.filter { e in
            switch query.filter {
            case "Links": guard Self.isLink(e.text) else { return false }
            case "Text": guard !Self.isLink(e.text) else { return false }
            default: break
            }
            return query.isEmpty || e.text.localizedCaseInsensitiveContains(query.text) || Fuzzy.score(query.text, e.text) != nil
        }
        if list.isEmpty && query.isEmpty {
            return [Section("Clipboard", [Item(id: "empty", title: "Nothing copied yet", subtitle: "Copy some text — it shows up here",
                                               icon: .symbol("tray"), primary: Action("Close") { .close })])]
        }
        return [Section(query.filter == "Links" ? "Links" : "History", list.map(item))]
    }

    private func item(_ e: Entry) -> Item {
        let firstLine = e.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? e.text
        let lines = e.text.split(whereSeparator: \.isNewline).count
        let meta = [e.source, e.date.relative, lines > 1 ? "\(lines) lines" : "\(e.text.count) chars"].compactMap { $0 }
        return Item(
            id: e.id.uuidString,
            title: String(firstLine.trimmingCharacters(in: .whitespaces).prefix(90)),
            subtitle: meta.joined(separator: " · "),
            icon: .symbol(Self.isLink(e.text) ? "link" : lines > 1 ? "text.alignleft" : "text.quote"),
            primary: Action("Copy", icon: .symbol("doc.on.doc")) { [weak self] in
                self?.promote(e.id)
                return .hud("Copied")
            },
            secondary: Action("Paste", icon: .symbol("arrow.down.doc")) { [weak self] in
                self?.promote(e.id)
                return .paste(e.text)
            },
            more: [
                Action("Save as Snippet", icon: .symbol("text.badge.plus"), shortcut: Shortcut("s", [.command])) {
                    SnippetsExtension.shared?.add(name: String(firstLine.prefix(40)), text: e.text)
                    return .hud("Saved to Snippets")
                },
                Action("Delete", icon: .symbol("trash"), shortcut: Shortcut("delete", [.command]), destructive: true) { [weak self] in
                    self?.entries.removeAll { $0.id == e.id }
                    return .stay
                },
                Action("Clear History", icon: .symbol("trash.slash"), shortcut: Shortcut("delete", [.command, .shift]), destructive: true) { [weak self] in
                    self?.entries.removeAll()
                    return .stay
                },
            ])
    }

    /// Moves the entry to the top and makes it the active clipboard.
    private func promote(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        var e = entries.remove(at: i)
        e.date = Date()
        entries.insert(e, at: 0)
        context.copy(e.text)
        changeCount = NSPasteboard.general.changeCount
    }

    private static func isLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.contains(" ") && (t.hasPrefix("http://") || t.hasPrefix("https://"))
    }
}
