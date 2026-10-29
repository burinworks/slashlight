import AppKit
import SlashlightKit

/// `> command` runs a shell command and streams its output inline. ⌘↵ opens it in Terminal instead.
/// stdin is /dev/null, so interactive commands get EOF; long-running ones can be stopped with ⌘.
final class TerminalExtension: Extension {
    private var history: [String] = []

    override var manifest: Manifest {
        Manifest(id: "terminal", title: "Terminal", subtitle: "Run shell commands — or type > in the bar", icon: .symbol("terminal"))
    }

    override var triggers: [Trigger] { [.prefix(">"), .command("terminal")] }

    override func activate(context: ExtensionContext) async {
        history = context.storage(.persistent).value([String].self, forKey: "history") ?? []
    }

    override func rootView() -> ListView? {
        ListView(title: manifest.title, icon: manifest.icon, placeholder: "Type a shell command…") { [unowned self] q in
            try await self.search(q)
        }
    }

    override func search(_ query: Query) async throws -> [Section] {
        let cmd = query.text.trimmingCharacters(in: .whitespaces)
        var sections: [Section] = []
        if !cmd.isEmpty {
            sections.append(Section("Run", [commandItem(cmd, title: "Run  \(cmd)", subtitle: "in \(Self.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")]))
        }
        let past = history.filter { $0 != cmd && (cmd.isEmpty || $0.localizedCaseInsensitiveContains(cmd)) }.prefix(20)
        sections.append(Section("History", past.map { commandItem($0, title: $0, subtitle: nil) }))
        return sections
    }

    private static var cwd: String { NSHomeDirectory() }

    private func commandItem(_ cmd: String, title: String, subtitle: String?) -> Item {
        Item(id: "run-\(cmd)", title: title, subtitle: subtitle, icon: .symbol("chevron.right.2"),
             primary: Action("Run Inline", icon: .symbol("play")) { [unowned self] in .push(self.run(cmd)) },
             secondary: Action("Open in Terminal", icon: .symbol("terminal")) { [weak self] in
                 self?.remember(cmd)
                 Shell.openInTerminal(cmd)
                 return .close
             },
             more: [
                Action("Copy Command", icon: .symbol("doc.on.doc"), shortcut: Shortcut("c", [.command, .shift])) { [weak self] in
                    self?.context.copy(cmd)
                    return .hud("Copied")
                },
                Action("Remove from History", icon: .symbol("trash"), shortcut: Shortcut("delete", [.command]), destructive: true) { [weak self] in
                    self?.history.removeAll { $0 == cmd }
                    self?.saveHistory()
                    return .stay
                },
             ])
    }

    private func remember(_ cmd: String) {
        history.removeAll { $0 == cmd }
        history.insert(cmd, at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
        saveHistory()
    }

    private func saveHistory() { context.storage(.persistent).set(history, forKey: "history") }

    /// Starts the command and returns the output screen.
    private func run(_ cmd: String) -> ListView {
        remember(cmd)
        let detail = DetailModel(text: "", isRunning: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-lc", cmd]
        process.currentDirectoryURL = URL(fileURLWithPath: Self.cwd)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    detail.text += chunk
                    if detail.text.count > 200_000 { detail.text = "…" + detail.text.suffix(150_000) }
                }
            }
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    detail.isRunning = false
                    if p.terminationStatus != 0 { detail.text += "\n[exit \(p.terminationStatus)]" }
                    self?.context.refresh()
                }
            }
        }
        do { try process.run() } catch {
            detail.text = error.localizedDescription
            detail.isRunning = false
        }

        return ListView(title: cmd, icon: .symbol("terminal"), placeholder: "Output actions…", detail: detail) { [weak self] q in
            guard let self else { return [] }
            var items: [Item] = []
            if detail.isRunning {
                items.append(Item(id: "stop", title: "Stop", subtitle: "Send SIGINT", icon: .symbol("stop.circle"),
                                  accessories: [.pill("Running", .orange)],
                                  primary: Action("Stop") { process.interrupt(); return .stay }))
            }
            items += [
                Item(id: "copy", title: "Copy Output", icon: .symbol("doc.on.doc"),
                     primary: Action("Copy Output") { self.context.copy(detail.text); return .hud("Output copied") },
                     secondary: Action("Paste Output") { .paste(detail.text) }),
                Item(id: "again", title: "Run Again", icon: .symbol("arrow.clockwise"),
                     primary: Action("Run Again") { .push(self.run(cmd)) }),
                Item(id: "terminal", title: "Open in Terminal", icon: .symbol("terminal"),
                     primary: Action("Open in Terminal") { Shell.openInTerminal(cmd); return .close }),
            ]
            return [Section(detail.isRunning ? "Running" : "Finished", items.filter { Fuzzy.score(q.text, $0.title) != nil })]
        }
    }
}
