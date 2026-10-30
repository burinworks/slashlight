import AppKit
import SlashlightKit

/// State of the panel: the screen stack, the query, results, selection and keyboard handling.
@MainActor
final class PaletteModel: ObservableObject {
    struct Screen {
        /// `nil` = the root screen (default search, `/` commands, prefixes).
        var view: ListView?
        var extensionID: String?
        var text = ""
        var selection = 0
        var filterIndex = 0
    }

    struct Row: Identifiable {
        let id: String
        let index: Int
        let item: Item
        let extensionID: String?
    }

    struct RenderedSection: Identifiable {
        let id: String
        let title: String
        var rows: [Row]
    }

    struct Hint: Identifiable {
        var id: String { keys + label }
        let keys: String
        let label: String
    }

    unowned let host: Host

    @Published var text = "" {
        didSet { if text != oldValue && !suppressSearch { selection = 0; search() } }
    }
    @Published private(set) var stack: [Screen] = [Screen()]
    @Published private(set) var sections: [RenderedSection] = []
    @Published var selection = 0
    @Published private(set) var filterIndex = 0
    @Published private(set) var isLoading = false
    /// Filters for the root screen, derived from result sections ("All", "Applications", "Files"…).
    @Published private(set) var rootFilters: [String] = []

    /// Set when the panel was opened by a hold-to-switch hotkey (⌥⇥): releasing it runs the selection.
    var holdModifier: Shortcut.Modifiers?

    private(set) var rows: [Row] = []
    private var unfiltered: [(String?, Section)] = []
    private var tasks: [Task<Void, Never>] = []
    private var generation = 0
    private var lastMouse: NSPoint = .zero
    private var suppressSearch = false

    init(host: Host) { self.host = host }

    var current: Screen { stack[stack.count - 1] }
    var currentView: ListView? { current.view }
    var isGrid: Bool { if case .grid = currentView?.layout { return true } else { return false } }
    var gridColumns: Int { if case .grid(let c) = currentView?.layout { return c } else { return 1 } }
    var selectedRow: Row? { rows.indices.contains(selection) ? rows[selection] : nil }

    var filters: [String] { currentView?.filters ?? rootFilters }
    var activeFilter: String? {
        if let v = currentView { return v.filters.isEmpty ? nil : v.filters[filterIndex % v.filters.count] }
        return filterIndex == 0 || rootFilters.isEmpty ? nil : rootFilters[filterIndex % rootFilters.count]
    }

    var placeholder: String { currentView?.placeholder ?? "Search apps and files, / for commands, > for terminal" }

    // MARK: Navigation

    func reset() {
        cancelTasks()
        stack = [Screen()]
        filterIndex = 0
        holdModifier = nil
        if text.isEmpty { search() } else { text = "" }
    }

    func open(_ ext: Extension) {
        guard let view = ext.rootView() else { return }
        RecentExtensions.record(ext.manifest.id)
        push(view, extensionID: ext.manifest.id)
    }

    func push(_ view: ListView, extensionID: String?) {
        stack[stack.count - 1].text = text
        stack[stack.count - 1].selection = selection
        stack[stack.count - 1].filterIndex = filterIndex
        stack.append(Screen(view: view, extensionID: extensionID))
        filterIndex = 0
        setTextSilently(view.initialText)
        search(selecting: view.initialSelection)
    }

    /// Shows a terminal tab, replacing the current screen when that is already a terminal.
    func showTerminal(_ session: TerminalSession) {
        TerminalManager.shared.shown(session)
        let isTerminal = EmbeddedScreen.of(currentView).map { e in TerminalManager.shared.sessions.contains { $0.embedded === e } } ?? false
        if isTerminal || EmbeddedScreen.of(currentView) != nil && current.extensionID == "terminal" {
            stack[stack.count - 1] = Screen(view: session.screen, extensionID: "terminal")
            setTextSilently("")
            search()
        } else {
            push(session.screen, extensionID: "terminal")
        }
    }

    var embedded: EmbeddedScreen? { EmbeddedScreen.of(currentView) }

    func pop() {
        guard stack.count > 1 else { return }
        stack.removeLast()
        filterIndex = current.filterIndex
        setTextSilently(current.text)
        search(selecting: current.selection)
    }

    func goHome() {
        stack = [Screen()]
        filterIndex = 0
        setTextSilently("")
        search()
    }

    func openSettings() {
        host.hide()
        SettingsWindowController.shared.show()
    }

    private func setTextSilently(_ value: String) {
        // Avoid the didSet search; callers run their own.
        suppressSearch = true
        text = value
        suppressSearch = false
    }

    // MARK: Search

    func refresh() { search(selecting: selection) }

    func search(selecting keep: Int = 0) {
        cancelTasks()
        generation += 1
        let gen = generation
        let text = self.text

        if let view = currentView {
            let ext = host.ext(current.extensionID)
            let filter = activeFilter
            isLoading = true
            tasks.append(Task {
                let results = (try? await view.search(Query(text: text, mode: .scoped, filter: filter))) ?? []
                guard gen == self.generation else { return }
                var parts: [(String?, Section)] = results.map { (ext?.manifest.id, $0) }
                if let ext { parts = self.permissionSections(for: ext) + parts }
                self.isLoading = false
                self.publish(parts, selecting: keep)
            })
            return
        }

        if text.isEmpty {
            publish(home(), selecting: keep)
            return
        }

        if text.hasPrefix("/") {
            let cmd = String(text.dropFirst())
            let providers = host.extensions.filter { $0.triggers.contains(.commands) }
            let entries: [(String?, Section)] = host.extensions
                .compactMap { ext -> (Int, Extension)? in
                    guard ext.rootView() != nil else { return nil }
                    guard let score = Fuzzy.score(cmd, [commandName(ext) ?? "", ext.manifest.title]) else { return nil }
                    return (score, ext)
                }
                .sorted { $0.0 > $1.0 }
                .map { (_, ext) in (ext.manifest.id, Section("Extensions", [entryItem(ext)])) }
            // User commands first, then extension entry points, then the other providers.
            let first = providers.prefix { $0.manifest.id == "commands" }
            stream(providers: Array(first), query: Query(text: cmd, mode: .command), fixedAfter: entries,
                   more: providers.filter { $0.manifest.id != "commands" }, gen: gen, keep: keep)
            return
        }

        for ext in host.extensions {
            for case .prefix(let p) in ext.triggers where text.hasPrefix(p) {
                let rest = String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                stream(providers: [ext], query: Query(text: rest, mode: .prefix(p)), gen: gen, keep: keep)
                return
            }
        }

        // Plain typing: quick answers and apps first, then extensions and commands whose name matches
        // ("switch window", "left half"), then files and the web fallback.
        let late: Set<String> = ["files", "web-search"]
        let defaults = host.extensions.filter { $0.triggers.contains(.defaultSearch) }
        let query = Query(text: text, mode: .default)
        let commandQuery = Query(text: text, mode: .command)
        let commandProviders = host.extensions.filter { $0.triggers.contains(.commands) && !$0.triggers.contains(.defaultSearch) }
        let entries: [(String?, Section)] = host.extensions
            .compactMap { ext -> (Int, Extension)? in
                guard ext.rootView() != nil,
                      let score = Fuzzy.score(text, [commandName(ext) ?? "", ext.manifest.title]), score >= Self.nameMatch else { return nil }
                return (score, ext)
            }
            .sorted { $0.0 > $1.0 }
            .map { (_, ext) in (ext.manifest.id, Section("Extensions", [entryItem(ext)])) }
        stream(defaults.filter { !late.contains($0.manifest.id) }.map { Job(ext: $0, query: query) },
               fixed: entries,
               after: (text.count >= 2 ? commandProviders.map { Job(ext: $0, query: commandQuery, nameMatchesOnly: 3) } : [])
                   + defaults.filter { late.contains($0.manifest.id) }.map { Job(ext: $0, query: query) },
               gen: gen, keep: keep)
    }

    /// A name counts as matching typed text in the root search only when it contains it, not by subsequence.
    private static let nameMatch = 400

    private struct Job {
        let ext: Extension
        let query: Query
        /// When set, keep only items whose title contains the query, at most this many.
        var nameMatchesOnly: Int?
    }

    private func stream(providers: [Extension], query: Query, fixedAfter: [(String?, Section)] = [],
                        more: [Extension] = [], gen: Int, keep: Int) {
        stream(providers.map { Job(ext: $0, query: query) }, fixed: fixedAfter,
               after: more.map { Job(ext: $0, query: query) }, gen: gen, keep: keep)
    }

    /// Runs jobs concurrently; results appear as each finishes, in job order with `fixed` in between.
    private func stream(_ before: [Job], fixed: [(String?, Section)], after: [Job], gen: Int, keep: Int) {
        let all = before + after
        var parts = [[(String?, Section)]?](repeating: nil, count: all.count)
        let assemble = { () -> [(String?, Section)] in
            let head = parts.prefix(before.count).compactMap { $0 }.flatMap { $0 }
            let tail = parts.suffix(after.count).compactMap { $0 }.flatMap { $0 }
            return head + fixed + tail
        }
        publish(fixed, selecting: keep)
        isLoading = !all.isEmpty
        var remaining = all.count
        for (i, job) in all.enumerated() {
            tasks.append(Task {
                var results = (try? await job.ext.search(job.query)) ?? []
                guard gen == self.generation, !Task.isCancelled else { return }
                if let limit = job.nameMatchesOnly {
                    results = results.map { section in
                        var s = section
                        s.items = Array(section.items.filter { (Fuzzy.score(job.query.text, $0.title) ?? 0) >= Self.nameMatch }.prefix(limit))
                        return s
                    }
                }
                parts[i] = results.map { (job.ext.manifest.id, $0) }
                remaining -= 1
                self.isLoading = remaining > 0
                self.publish(assemble(), selecting: keep)
            })
        }
    }

    private func publish(_ parts: [(String?, Section)], selecting keep: Int) {
        unfiltered = parts
        if currentView == nil && text.isEmpty { rootFilters = []; filterIndex = 0 }
        if currentView == nil && !text.isEmpty {
            var titles: [String] = []
            for (_, s) in parts where !s.items.isEmpty && !titles.contains(s.title) { titles.append(s.title) }
            let newFilters = titles.count > 1 ? ["All"] + titles : []
            if newFilters != rootFilters {
                let active = activeFilter
                rootFilters = newFilters
                filterIndex = active.flatMap { newFilters.firstIndex(of: $0) } ?? 0
            }
        }
        render(selecting: keep)
    }

    private func render(selecting keep: Int) {
        let rootFilter = currentView == nil ? activeFilter : nil
        var out: [RenderedSection] = []
        var flat: [Row] = []
        var seen = Set<String>()
        for (extID, section) in unfiltered where !section.items.isEmpty {
            if let rootFilter, section.title != rootFilter { continue }
            let rows: [Row] = section.items.map { item in
                var id = "\(extID ?? "-")|\(section.title)|\(item.id)"
                while seen.contains(id) { id += "'" }
                seen.insert(id)
                let row = Row(id: id, index: flat.count, item: item, extensionID: extID)
                flat.append(row)
                return row
            }
            if let last = out.last, last.title == section.title {
                out[out.count - 1].rows += rows
            } else {
                out.append(RenderedSection(id: "\(out.count)|\(section.title)", title: section.title, rows: rows))
            }
        }
        rows = flat
        sections = out
        selection = min(max(keep, 0), max(flat.count - 1, 0))
    }

    private func cancelTasks() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        isLoading = false
    }

    // MARK: Root content

    private func commandName(_ ext: Extension) -> String? {
        for case .command(let name) in ext.triggers { return name }
        return nil
    }

    private func entryItem(_ ext: Extension, idPrefix: String = "") -> Item {
        let m = ext.manifest
        return Item(id: "\(idPrefix)open-\(m.id)", title: m.title, subtitle: m.subtitle, icon: m.icon,
                    accessories: commandName(ext).map { [.text("/\($0)")] } ?? [],
                    primary: Action("Open", icon: .symbol("arrow.right")) { [weak ext] in
                        guard let view = ext?.rootView() else { return .stay }
                        return .push(view)
                    })
    }

    private func home() -> [(String?, Section)] {
        // Up to five recently used extensions, then every extension A to Z.
        let openable = host.extensions.filter { $0.rootView() != nil }
        let byID = Dictionary(openable.map { ($0.manifest.id, $0) }, uniquingKeysWith: { a, _ in a })
        let recent = RecentExtensions.ids.compactMap { byID[$0] }.prefix(5)
        var parts: [(String?, Section)] = recent
            .map { ($0.manifest.id, Section("Recent", [entryItem($0, idPrefix: "recent-")])) }
        parts += openable
            .sorted { $0.manifest.title.localizedCaseInsensitiveCompare($1.manifest.title) == .orderedAscending }
            .map { ($0.manifest.id, Section("All Extensions", [entryItem($0)])) }
        parts.append((nil, Section("Slashlight", [
            Item(id: "settings", title: "Settings", subtitle: "Permissions, hotkeys, extensions folder",
                 icon: .symbol("gearshape"), accessories: [.keycap(Shortcut(",", .command))],
                 primary: Action("Open Settings") { SettingsWindowController.shared.show(); return .close }),
        ])))
        return parts
    }

    private func permissionSections(for ext: Extension) -> [(String?, Section)] {
        let missing = ext.permissions.filter { !Permissions.isGranted($0) && $0 != .automation }
        guard !missing.isEmpty else { return [] }
        return [(ext.manifest.id, Section("Permissions needed", missing.map { p in
            Item(id: "perm-\(p.rawValue)", title: "Allow \(Permissions.title(p))", subtitle: Permissions.reason(p),
                 icon: .symbol("lock.open"), accessories: [.pill("Missing", .orange)],
                 primary: Action("Open System Settings") { Permissions.request(p); return .close })
        }))]
    }

    // MARK: Running actions

    func run(_ action: Action, from row: Row?) {
        if let id = row?.extensionID ?? current.extensionID { RecentExtensions.record(id) }
        Task {
            do {
                handle(try await action.run(), extensionID: row?.extensionID)
            } catch {
                host.showHUD("⚠︎ \(error.localizedDescription)")
            }
        }
    }

    private func handle(_ outcome: Outcome, extensionID: String?) {
        switch outcome {
        case .close: host.hide()
        case .stay: search(selecting: selection)
        case .push(let view): push(view, extensionID: extensionID ?? current.extensionID)
        case .pop: pop()
        case .hud(let message):
            host.hide()
            host.showHUD(message)
        case .paste(let text): host.paste(text)
        }
    }

    func runPrimary(_ index: Int? = nil) {
        let row = index.flatMap { rows.indices.contains($0) ? rows[$0] : nil } ?? selectedRow
        guard let row, let action = row.item.primary else { return }
        run(action, from: row)
    }

    func runSecondary() {
        guard let row = selectedRow else { return }
        if let action = row.item.secondary { run(action, from: row) } else { runPrimary() }
    }

    func showActions() {
        guard let row = selectedRow, !row.item.actions.isEmpty else { return }
        let item = row.item
        let view = ListView(title: "Actions", icon: .symbol("command"), placeholder: "Actions for \(item.title)…") { q in
            [Section(item.title, item.actions.enumerated().compactMap { i, a in
                guard Fuzzy.score(q.text, a.title) != nil else { return nil }
                let key: Shortcut? = i == 0 ? .primary : i == 1 ? .secondary : a.shortcut
                return Item(id: "\(i)-\(a.id)", title: a.title, icon: a.icon ?? .symbol(a.isDestructive ? "trash" : "bolt"),
                            accessories: key.map { [.keycap($0)] } ?? [],
                            primary: Action(a.title) {
                                let outcome = try await a.run()
                                if case .stay = outcome { return .pop }
                                return outcome
                            })
            })]
        }
        push(view, extensionID: row.extensionID)
    }

    // MARK: Input

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = (selection + delta + rows.count) % rows.count
    }

    func cycleFilter(_ delta: Int) {
        let count = filters.count
        guard count > 0 else { return }
        filterIndex = (filterIndex + delta + count) % count
        if currentView == nil { render(selecting: 0) } else { search() }
    }

    func hover(_ index: Int) {
        // Ignore hover caused by the list scrolling under a still mouse.
        let loc = NSEvent.mouseLocation
        guard loc != lastMouse else { return }
        lastMouse = loc
        selection = index
    }

    func click(_ index: Int) {
        selection = index
        if NSEvent.modifierFlags.contains(.command) { runSecondary() } else { runPrimary(index) }
    }

    /// Returns true when the key was handled and must not reach the text field.
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = Shortcut.Modifiers(event.modifierFlags)
        let key = KeyCodes.key(for: event)
        let plain = mods.subtracting(.shift).isEmpty
        if let embedded { return embedded.handleKey(event, self) || editingShortcut(key, mods) }
        if editingShortcut(key, mods) { return true }

        switch (key, mods) {
        case ("escape", _):
            host.hide()
        case ("up", _), ("p", [.control]):
            move(isGrid && key == "up" ? -gridColumns : -1)
        case ("down", _), ("n", [.control]):
            move(isGrid && key == "down" ? gridColumns : 1)
        case ("left", []) where isGrid:
            move(-1)
        case ("right", []) where isGrid:
            move(1)
        case ("return", []), ("enter", []):
            runPrimary()
        case ("return", [.command]), ("enter", [.command]):
            runSecondary()
        case ("tab", []):
            if holdModifier != nil || filters.isEmpty { move(1) } else { cycleFilter(1) }
        case ("tab", [.shift]):
            if holdModifier != nil || filters.isEmpty { move(-1) } else { cycleFilter(-1) }
        case ("delete", []) where text.isEmpty && stack.count > 1:
            pop()
        case ("k", [.command]):
            showActions()
        case ("e", [.command]):
            goHome()
        case (",", [.command]):
            openSettings()
        case ("tab", [.control]):
            if let s = TerminalManager.shared.lastShown ?? TerminalManager.shared.sessions.last { showTerminal(s) }
        case ("t", [.command]) where current.extensionID == "terminal" || text.hasPrefix(">"):
            showTerminal(TerminalManager.shared.start(command: nil))
        case (let k, [.command]) where Int(k).map({ (1...9).contains($0) }) == true:
            runPrimary(Int(k)! - 1)
        default:
            if plain { return false }
            guard let row = selectedRow,
                  let action = row.item.actions.first(where: { $0.shortcut == Shortcut(key, mods) }) else { return false }
            run(action, from: row)
        }
        return true
    }

    func handleFlagsChanged(_ event: NSEvent) {
        guard let hold = holdModifier else { return }
        if Shortcut.Modifiers(event.modifierFlags).isDisjoint(with: hold) {
            holdModifier = nil
            runPrimary()
        }
    }

    // MARK: Footer

    /// The app has no Edit menu (it lives in the menu bar only), so standard editing keys are sent by hand.
    private func editingShortcut(_ key: String, _ mods: Shortcut.Modifiers) -> Bool {
        let selectors: [String: Selector] = [
            "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)), "x": #selector(NSText.cut(_:)),
            "a": #selector(NSText.selectAll(_:)), "z": Selector(("undo:")),
        ]
        if mods == [.command], let sel = selectors[key] { return NSApp.sendAction(sel, to: nil, from: nil) }
        if mods == [.command, .shift], key == "z" { return NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
        return false
    }

    var hints: [Hint] {
        if let embedded { return embedded.hints() }
        var out: [Hint] = []
        if let item = selectedRow?.item {
            if let p = item.primary { out.append(Hint(keys: "↵", label: p.title)) }
            if let s = item.secondary { out.append(Hint(keys: "⌘↵", label: s.title)) }
            if item.actions.count > 2 { out.append(Hint(keys: "⌘K", label: "Actions")) }
        }
        out.append(Hint(keys: isGrid ? "←→" : "↑↓", label: "Navigate"))
        if let f = activeFilter ?? filters.first { out.append(Hint(keys: "tab", label: f)) }
        if stack.count > 1 { out.append(Hint(keys: "⌫", label: "Back")) }
        return Array(out.prefix(6))
    }
}
