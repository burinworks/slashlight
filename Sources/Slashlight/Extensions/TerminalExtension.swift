import AppKit
import Darwin
import SlashlightKit
import SwiftTerm

/// `> command` opens a real terminal tab inside the panel and runs the command there.
/// Tabs keep running when you go back to search or close the panel; the tab strip brings them back.
final class TerminalExtension: Extension {
    private var history: [String] = []

    override var manifest: Manifest {
        Manifest(id: "terminal", title: "Terminal", subtitle: "Terminal tabs inside Slashlight — or type > in the bar", icon: .symbol("terminal"))
    }

    override var triggers: [Trigger] { [.prefix(">"), .command("terminal")] }

    override func activate(context: ExtensionContext) async {
        history = context.storage(.persistent).value([String].self, forKey: "history") ?? []
        TerminalManager.shared.onCommand = { [weak self] in self?.remember($0) }
    }

    override func rootView() -> ListView? {
        ListView(title: manifest.title, icon: manifest.icon, placeholder: "Type a shell command, or pick a terminal…") { [unowned self] q in
            try await self.search(q)
        }
    }

    override func search(_ query: Query) async throws -> [Section] {
        let cmd = query.text.trimmingCharacters(in: .whitespaces)
        let manager = TerminalManager.shared
        var sections: [Section] = []
        if !cmd.isEmpty {
            sections.append(Section("Run", [commandItem(cmd, title: "Run  \(cmd)", subtitle: "In a new terminal tab · ~")]))
        } else {
            sections.append(Section("Run", [
                Item(id: "new", title: "New Terminal", subtitle: "Shell in your home folder", icon: .symbol("plus.rectangle"),
                     accessories: [.keycap(Shortcut("t", .command))],
                     primary: Action("Open", icon: .symbol("terminal")) { .push(manager.start(command: nil).screen) },
                     secondary: Action("Open Terminal.app", icon: .symbol("terminal")) {
                         NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                         return .close
                     }),
            ]))
        }
        let sessions = manager.sessions.filter { cmd.isEmpty || Fuzzy.score(cmd, [$0.title, $0.activity]) != nil }
        sections.append(Section("Open Terminals", sessions.map(sessionItem)))
        let past = history.filter { $0 != cmd && (cmd.isEmpty || $0.localizedCaseInsensitiveContains(cmd)) }.prefix(20)
        sections.append(Section("History", past.map { commandItem($0, title: $0, subtitle: nil) }))
        return sections
    }

    private func sessionItem(_ s: TerminalSession) -> Item {
        Item(id: "session-\(s.id)", title: s.title, subtitle: s.activity, icon: .symbol("terminal"),
             accessories: [s.statusPill],
             primary: Action("Show Terminal", icon: .symbol("terminal")) { .push(s.screen) },
             secondary: Action("Close Terminal", icon: .symbol("xmark"), destructive: true) {
                 TerminalManager.shared.close(s)
                 return .stay
             })
    }

    private func commandItem(_ cmd: String, title: String, subtitle: String?) -> Item {
        Item(id: "run-\(cmd)", title: title, subtitle: subtitle, icon: .symbol("chevron.right.2"),
             primary: Action("Run in New Tab", icon: .symbol("play")) { .push(TerminalManager.shared.start(command: cmd).screen) },
             secondary: Action("Open in Terminal.app", icon: .symbol("terminal")) { [weak self] in
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
}

/// All open terminal tabs. They outlive the panel: closing Slashlight does not stop them.
@MainActor
final class TerminalManager: ObservableObject {
    static let shared = TerminalManager()

    @Published private(set) var sessions: [TerminalSession] = []
    /// The tab shown last, so ⌃⇥ from search returns to it.
    @Published private(set) var lastShown: TerminalSession?
    var onCommand: ((String) -> Void)?
    private var timer: Timer?

    @discardableResult
    func start(command: String?, directory: String = NSHomeDirectory()) -> TerminalSession {
        let session = TerminalSession(command: command, directory: directory)
        sessions.append(session)
        if let command { onCommand?(command) }
        if timer == nil {
            // Child processes of each shell tell us whether a task is running; poll them once a second.
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        }
        return session
    }

    func close(_ session: TerminalSession) {
        session.terminate()
        sessions.removeAll { $0 === session }
        if lastShown === session { lastShown = sessions.last }
        if sessions.isEmpty { timer?.invalidate(); timer = nil }
    }

    func shown(_ session: TerminalSession) { lastShown = session }

    func neighbor(of session: TerminalSession, _ delta: Int) -> TerminalSession? {
        guard let i = sessions.firstIndex(where: { $0 === session }), sessions.count > 1 else { return nil }
        return sessions[(i + delta + sessions.count) % sessions.count]
    }

    private func poll() {
        let visible = Host.shared.isVisible ? EmbeddedScreen.of(Host.shared.model.currentView).flatMap { s in sessions.first { $0.embedded === s } } : nil
        for s in sessions {
            if let finished = s.poll(), s !== visible {
                Host.shared.showHUD("✓ \(finished) finished in “\(s.title)”")
            }
        }
    }
}

/// One shell in a pseudo-terminal, with its own SwiftTerm view.
@MainActor
final class TerminalSession: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        /// A foreground task is running: its process name and when it started.
        case busy(String, Date)
        case exited(Int32?)
    }

    let id = UUID()
    let view: LocalProcessTerminalView
    @Published var title: String
    @Published var directory: String
    @Published private(set) var state: State = .idle
    private(set) var embedded: EmbeddedScreen?
    private var shellPid: pid_t = 0

    init(command: String?, directory: String) {
        self.directory = directory
        title = command ?? (directory as NSString).lastPathComponent
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: Theme.width - 16, height: 400))
        super.init()
        view.processDelegate = self
        view.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.optionAsMetaKey = false
        applyTheme(dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Slashlight"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        // A leading "-" in argv[0] makes it a login shell, so PATH and the user's profile are set up like in Terminal.app.
        view.startProcess(executable: shell, args: [], environment: env.map { "\($0.key)=\($0.value)" },
                          execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: directory)
        shellPid = view.process.shellPid
        if let command {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.send(command + "\n") }
        }
    }

    func send(_ text: String) { view.send(data: Array(text.utf8)[...]) }

    func terminate() {
        if case .exited = state { return }
        view.terminate()
    }

    var isBusy: Bool { if case .busy = state { return true } else { return false } }

    /// Short status line: what is running and for how long.
    var activity: String {
        let dir = directory.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        switch state {
        case .idle: return "Idle · \(dir)"
        case .busy(let name, let since): return "Running \(name) · \(Self.duration(since)) · \(dir)"
        case .exited(let code): return "Exited\(code.map { " (\($0))" } ?? "") · \(dir)"
        }
    }

    var statusPill: Accessory {
        switch state {
        case .idle: return .pill("Idle", .gray)
        case .busy: return .pill("Running", .green)
        case .exited(let code): return .pill(code == 0 ? "Exited" : "Exited \(code.map(String.init) ?? "")", code == 0 ? .gray : .red)
        }
    }

    static func duration(_ since: Date) -> String {
        let s = Int(Date().timeIntervalSince(since))
        return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m \(s % 60)s" : "\(s / 3600)h \(s / 60 % 60)m"
    }

    /// Updates the busy state from the shell's child processes. Returns the task name when one just finished.
    func poll() -> String? {
        if case .exited = state { return nil }
        if let cwd = Self.workingDirectory(of: shellPid), cwd != directory { directory = cwd }
        var pids = [pid_t](repeating: 0, count: 64)
        let count = Int(proc_listchildpids(shellPid, &pids, Int32(MemoryLayout<pid_t>.size * pids.count)))
        let children = pids.prefix(max(count, 0)).filter { $0 > 0 }
        if let child = children.first {
            var name = [CChar](repeating: 0, count: 256)
            proc_name(child, &name, UInt32(name.count))
            let task = String(cString: name)
            if case .busy(let current, _) = state, current == task { return nil }
            if case .busy(_, let since) = state { state = .busy(task, since) } else { state = .busy(task, Date()) }
            return nil
        }
        if case .busy(let task, let since) = state {
            state = .idle
            // Only announce tasks long enough that you may have walked away.
            return Date().timeIntervalSince(since) > 3 ? task : nil
        }
        return nil
    }

    /// The shell's current folder, read from the kernel (works without shell integration).
    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    func applyTheme(dark: Bool) {
        view.nativeBackgroundColor = NSColor(hex: dark ? 0x161618 : 0xFBFBFC)
        view.nativeForegroundColor = NSColor(hex: dark ? 0xE8E8EA : 0x1A1A1A)
        view.caretColor = NSColor(hex: dark ? 0x8AB4FF : 0x1F5FBF)
    }

    /// The panel screen for this tab: the terminal fills the panel, the tab strip sits above it.
    lazy var screen: ListView = {
        let list = ListView(title: title, icon: .symbol("terminal"), placeholder: "") { _ in [] }
        let screen = EmbeddedScreen(view: view, height: 440, hints: { [weak self] in
            [PaletteModel.Hint(keys: "esc", label: self?.isBusy == true ? "To terminal" : "Close panel"),
             PaletteModel.Hint(keys: "⌘⌫", label: "Back to search"),
             PaletteModel.Hint(keys: "⌘T", label: "New tab"),
             PaletteModel.Hint(keys: "⌃⇥", label: "Next tab"),
             PaletteModel.Hint(keys: "⌘W", label: "Close tab")]
        }) { [weak self] event, model in
            guard let self else { return false }
            return self.handleKey(event, model: model)
        }
        screen.attach(to: list)
        embedded = screen
        return list
    }()

    private func handleKey(_ event: NSEvent, model: PaletteModel) -> Bool {
        let mods = Shortcut.Modifiers(event.modifierFlags)
        let manager = TerminalManager.shared
        switch (KeyCodes.key(for: event), mods) {
        case ("escape", []) where !isBusy:
            // At an idle prompt Esc closes the panel; while a program runs (vim, less) it belongs to the program.
            model.host.hide()
        case ("delete", [.command]), ("[", [.command]):
            model.pop()
        case ("t", [.command]):
            model.showTerminal(manager.start(command: nil, directory: directory))
        case ("w", [.command]):
            let next = manager.neighbor(of: self, 1)
            manager.close(self)
            if let next { model.showTerminal(next) } else { model.pop() }
        case ("tab", [.control]):
            if let next = manager.neighbor(of: self, 1) { model.showTerminal(next) }
        case ("tab", [.control, .shift]):
            if let prev = manager.neighbor(of: self, -1) { model.showTerminal(prev) }
        case (let k, [.command]) where Int(k).map({ (1...9).contains($0) }) == true:
            if let s = manager.sessions[safe: Int(k)! - 1] { model.showTerminal(s) }
        case ("c", [.command]):
            view.copy(self)
        case ("v", [.command]):
            view.paste(self)
        case ("a", [.command]):
            view.selectAll(self)
        case ("k", [.command]):
            // Clear screen and scrollback, like Terminal.app.
            send("\u{0C}")
        case ("=", [.command]), ("+", [.command]), ("-", [.command]):
            let size = view.font.pointSize + (KeyCodes.key(for: event) == "-" ? -1 : 1)
            view.font = .monospacedSystemFont(ofSize: min(max(size, 9), 24), weight: .regular)
        default:
            return false
        }
        return true
    }
}

extension TerminalSession: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated {
            if !title.isEmpty { self.title = title }
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated {
            guard let directory, let url = URL(string: directory) else { return }
            self.directory = url.path.isEmpty ? directory : url.path
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            self.state = .exited(exitCode)
        }
    }
}
