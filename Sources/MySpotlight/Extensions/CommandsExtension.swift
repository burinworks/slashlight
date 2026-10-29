import AppKit
import SpotlightKit

/// User-defined `/commands` from `~/Library/Application Support/MySpotlight/commands/commands.json`.
final class CommandsExtension: Extension {
    struct Command: Codable {
        /// Typed after `/`, e.g. "turn-light-on".
        var name: String
        var title: String?
        var icon: String?
        /// "shell" | "url" | "shortcut" | "http" | "applescript"
        var type: String
        /// Shell command, URL, Shortcuts name, request URL or AppleScript source.
        var run: String
        var method: String?
        var body: String?
        var headers: [String: String]?
    }

    private var commands: [Command] = []
    private var loadedAt: Date?

    override var manifest: Manifest {
        Manifest(id: "commands", title: "Commands", subtitle: "Your own /commands: scripts, URLs, Shortcuts, HTTP", icon: .symbol("command"))
    }

    override var triggers: [Trigger] { [.commands, .command("commands")] }

    private var file: URL { context.supportDirectory.appendingPathComponent("commands.json") }

    override func activate(context: ExtensionContext) async {
        if !FileManager.default.fileExists(atPath: file.path) { writeExamples() }
        load()
    }

    override func search(_ query: Query) async throws -> [Section] {
        reloadIfChanged()
        let matches = commands
            .compactMap { c -> (Int, Command)? in Fuzzy.score(query.text, c.name).map { ($0, c) } }
            .sorted { $0.0 > $1.0 }
            .map { item($0.1) }
        var sections = [Section("Commands", matches)]
        if query.mode == .scoped || Fuzzy.score(query.text, "edit commands") != nil && !query.isEmpty {
            sections.append(Section("Manage", [
                Item(id: "edit", title: "Edit commands.json", subtitle: file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                     icon: .symbol("pencil"),
                     primary: Action("Open in Editor") { [file] in NSWorkspace.shared.open(file); return .close },
                     secondary: Action("Show in Finder") { [file] in NSWorkspace.shared.activateFileViewerSelecting([file]); return .close }),
            ]))
        }
        return sections
    }

    private func item(_ c: Command) -> Item {
        let symbol = c.icon ?? ["shell": "terminal", "url": "link", "shortcut": "square.stack.3d.up", "http": "network", "applescript": "applescript"][c.type] ?? "bolt"
        return Item(id: c.name, title: "/\(c.name)", subtitle: [c.title, c.type].compactMap { $0 }.joined(separator: " · "),
                    icon: .symbol(symbol),
                    primary: Action("Run Command", icon: .symbol("play")) { try await Self.execute(c) },
                    secondary: Action("Copy Definition", icon: .symbol("doc.on.doc")) { [weak self] in
                        self?.context.copy(c.run)
                        return .hud("Copied")
                    })
    }

    static func execute(_ c: Command) async throws -> Outcome {
        switch c.type {
        case "url":
            guard let url = URL(string: c.run) else { return .hud("Invalid URL") }
            NSWorkspace.shared.open(url)
            return .close
        case "shortcut":
            let r = await Shell.run("/usr/bin/shortcuts run \(Shell.quote(c.run))")
            return .hud(r.status == 0 ? "Ran “\(c.run)”" : "Shortcut failed: \(r.output.prefix(80))")
        case "http":
            guard let url = URL(string: c.run) else { return .hud("Invalid URL") }
            var req = URLRequest(url: url)
            req.httpMethod = c.method ?? "GET"
            req.httpBody = c.body?.data(using: .utf8)
            c.headers?.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (_, resp) = try await URLSession.shared.data(for: req)
            return .hud("\(c.title ?? c.name): HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        case "applescript":
            var error: NSDictionary?
            let result = NSAppleScript(source: c.run)?.executeAndReturnError(&error)
            if let error { return .hud("AppleScript error: \(error[NSAppleScript.errorMessage] ?? "")") }
            return .hud(result?.stringValue ?? "Done")
        default:
            let r = await Shell.run(c.run)
            let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.status != 0 { return .hud("Failed (\(r.status)): \(out.prefix(80))") }
            return .hud(out.isEmpty ? "Done" : String(out.prefix(120)))
        }
    }

    private func load() {
        do {
            commands = try JSONDecoder().decode([Command].self, from: Data(contentsOf: file))
        } catch {
            commands = []
            context.showHUD("commands.json: \(error.localizedDescription)")
        }
        loadedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func reloadIfChanged() {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if modified != loadedAt { load() }
    }

    private func writeExamples() {
        let examples = [
            Command(name: "turn-light-on", title: "Turn the lights on (runs the Shortcut “Turn Light On”)", type: "shortcut", run: "Turn Light On"),
            Command(name: "say-hello", title: "Speak a greeting", type: "shell", run: "say 'Hello from My Spotlight'"),
            Command(name: "my-ip", title: "Show my public IP", type: "shell", run: "curl -s https://api.ipify.org"),
            Command(name: "github", title: "Open GitHub", type: "url", run: "https://github.com"),
            Command(name: "toggle-dark-mode", title: "Toggle dark mode", type: "applescript",
                    run: "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"),
        ]
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? enc.encode(examples).write(to: file)
    }
}

extension Shell {
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
