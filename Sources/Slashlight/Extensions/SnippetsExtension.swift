import AppKit
import SlashlightKit

/// Named text you can paste anywhere. Stored on disk, so it survives restarts.
/// Placeholders expanded on use: {clipboard}, {date}, {time}.
final class SnippetsExtension: Extension {
    struct Snippet: Codable {
        var id = UUID()
        var name: String
        var text: String
        var created = Date()
    }

    /// Lets other built-ins (clipboard "Save as Snippet") add snippets.
    static weak var shared: SnippetsExtension?

    private var snippets: [Snippet] = []

    override var manifest: Manifest {
        Manifest(id: "snippets", title: "Snippets", subtitle: "Saved text you can paste anywhere", icon: .symbol("text.quote"))
    }

    override var triggers: [Trigger] { [.command("snippets")] }

    override func activate(context: ExtensionContext) async {
        Self.shared = self
        snippets = context.storage(.persistent).value([Snippet].self, forKey: "snippets") ?? []
    }

    override func rootView() -> ListView? {
        ListView(title: manifest.title, icon: manifest.icon, placeholder: "Search snippets, or type a name to create one…") { [unowned self] q in
            try await self.search(q)
        }
    }

    func add(name: String, text: String) {
        snippets.insert(Snippet(name: name, text: text), at: 0)
        save()
    }

    private func save() { context.storage(.persistent).set(snippets, forKey: "snippets") }

    override func search(_ query: Query) async throws -> [Section] {
        let list = snippets
            .compactMap { s -> (Int, Snippet)? in Fuzzy.score(query.text, [s.name, s.text]).map { ($0, s) } }
            .sorted { query.isEmpty ? $0.1.name.localizedCaseInsensitiveCompare($1.1.name) == .orderedAscending : $0.0 > $1.0 }
            .map { item($0.1) }

        var create: [Item] = []
        let name = query.text.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty && !snippets.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            create.append(Item(id: "create", title: "Create snippet “\(name)”", subtitle: "Opens an editor: multiple lines, ⌘↵ saves",
                               icon: .symbol("plus"), primary: Action("Create Snippet") { [unowned self] in .push(self.editor(name: name)) }))
            if let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty {
                create.append(Item(id: "create-clip", title: "Create “\(name)” from clipboard", subtitle: String(clip.prefix(90)),
                                   icon: .symbol("doc.on.clipboard"),
                                   primary: Action("Save") { [unowned self] in self.store(name: name, text: clip, editing: nil); return .stay },
                                   secondary: Action("Edit First") { [unowned self] in .push(self.editor(name: name, text: clip)) }))
            }
        } else if name.isEmpty {
            create.append(Item(id: "create-hint", title: "New snippet…", subtitle: "Type a name in the bar first", icon: .symbol("plus"),
                               primary: Action("Create Snippet") { .stay }))
        }
        return [Section("Snippets", list), Section("Create", create)]
    }

    /// Multi-line editor for a snippet's text. ⌘↵ saves.
    private func editor(name: String, text: String? = nil, editing: UUID? = nil) -> ListView {
        let existing = text ?? snippets.first { $0.id == editing }?.text ?? ""
        return TextEditorScreen.make(title: editing == nil ? "New: \(name)" : "Edit: \(name)", icon: .symbol("text.badge.plus"),
                                     text: existing, placeholder: "Snippet text — supports {clipboard}, {date}, {time}") { [weak self] text in
            self?.store(name: name, text: text, editing: editing)
        }
    }

    private func store(name: String, text: String, editing: UUID?) {
        if let editing, let i = snippets.firstIndex(where: { $0.id == editing }) {
            snippets[i].text = text
            save()
        } else {
            add(name: name, text: text)
        }
        context.showHUD("Snippet “\(name)” saved")
        context.refresh()
    }

    private func item(_ s: Snippet) -> Item {
        Item(
            id: s.id.uuidString, title: s.name,
            subtitle: s.text.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(90).description,
            icon: .symbol("text.quote"),
            primary: Action("Copy", icon: .symbol("doc.on.doc")) { [weak self] in
                self?.context.copy(Self.expand(s.text))
                return .hud("Copied “\(s.name)”")
            },
            secondary: Action("Paste", icon: .symbol("arrow.down.doc")) { .paste(Self.expand(s.text)) },
            more: [
                Action("Edit Text", icon: .symbol("pencil"), shortcut: Shortcut("e", [.command, .shift])) { [unowned self] in
                    .push(self.editor(name: s.name, editing: s.id))
                },
                Action("Delete Snippet", icon: .symbol("trash"), shortcut: Shortcut("delete", [.command]), destructive: true) { [weak self] in
                    self?.snippets.removeAll { $0.id == s.id }
                    self?.save()
                    return .stay
                },
            ])
    }

    static func expand(_ text: String) -> String {
        let now = Date()
        return text
            .replacingOccurrences(of: "{clipboard}", with: NSPasteboard.general.string(forType: .string) ?? "")
            .replacingOccurrences(of: "{date}", with: now.formatted(date: .abbreviated, time: .omitted))
            .replacingOccurrences(of: "{time}", with: now.formatted(date: .omitted, time: .shortened))
    }
}
