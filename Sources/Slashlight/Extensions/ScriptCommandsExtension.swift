import AppKit
import SlashlightKit

/// Raycast Script Commands, unchanged: every executable in `~/Library/Application Support/Slashlight/script-commands/`
/// with `@raycast.*` metadata comments becomes a `/command` named after its file.
/// Arguments follow the name (`/hello-world Alex`), split on whitespace; the last argument takes the rest of the text.
final class ScriptCommandsExtension: Extension {
    /// `@raycast.argument1 { "type": "text", "placeholder": "Name", "optional": true }`
    struct Argument: Decodable {
        var type: String?
        var placeholder: String?
        var optional: Bool?
        var percentEncoded: Bool?
    }

    struct Script {
        let url: URL
        /// Slug of the file name, typed after `/`.
        let name: String
        let title: String
        /// "silent" | "compact" | "fullOutput" | "inline"
        let mode: String
        let packageName: String?
        let description: String?
        let icon: Icon
        let arguments: [Argument]
        let needsConfirmation: Bool
        let directory: URL
        /// Inline mode: how long a result stays fresh (`@raycast.refreshTime`, never under 10 s).
        let refreshTime: TimeInterval
        let isExecutable: Bool
    }

    private var scripts: [Script] = []
    private var scannedStamp: Date?
    /// Inline mode: first output line per script, and when it was produced.
    private var inline: [String: (line: String, date: Date)] = [:]
    private var inlineRunning: Set<String> = []

    override var manifest: Manifest {
        Manifest(id: "script-commands", title: "Script Commands",
                 subtitle: "Raycast-compatible scripts; the ones from github.com/raycast/script-commands work as-is", icon: .symbol("scroll"))
    }

    override var triggers: [Trigger] { [.commands, .command("scripts")] }

    private var folder: URL { context.supportDirectory }

    override func activate(context: ExtensionContext) async {
        seedExampleIfEmpty()
        rescanIfChanged()
    }

    override func rootView() -> ListView? {
        ListView(title: manifest.title, icon: manifest.icon, placeholder: "Search script commands…") { [unowned self] q in
            try await self.search(q)
        }
    }

    override func search(_ query: Query) async throws -> [Section] {
        rescanIfChanged()
        // "hello-world Alex": the first word picks the script, the rest are its arguments.
        let text = query.text.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = parts.count > 1 ? parts[1] : ""
        let matches = scripts
            .compactMap { s -> (Int, Script, [String])? in
                if !rest.isEmpty && !s.arguments.isEmpty {
                    return Fuzzy.score(parts[0], s.name).map { ($0, s, Self.split(rest, into: s.arguments.count)) }
                }
                return Fuzzy.score(text, [s.name, s.title, s.packageName ?? ""]).map { ($0, s, []) }
            }
            .sorted { $0.0 > $1.0 }
            .map { item($0.1, arguments: $0.2) }
        var sections = [Section("Script Commands", matches)]
        if query.mode == .scoped {
            sections.append(Section("Manage", [
                Item(id: "folder", title: "Open Script Commands Folder", subtitle: folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                     icon: .symbol("folder"),
                     primary: Action("Open in Finder") { [folder] in NSWorkspace.shared.open(folder); return .close },
                     secondary: Action("Copy Path") { [weak self, folder] in self?.context.copy(folder.path); return .hud("Copied") }),
                Item(id: "browse", title: "Browse Raycast Script Commands", subtitle: "github.com/raycast/script-commands — drop scripts into the folder",
                     icon: .symbol("safari"),
                     primary: Action("Open in Browser") {
                         NSWorkspace.shared.open(URL(string: "https://github.com/raycast/script-commands")!)
                         return .close
                     }),
            ]))
        }
        return sections
    }

    private func item(_ s: Script, arguments args: [String]) -> Item {
        let missing = s.arguments.enumerated()
            .filter { i, a in a.optional != true && (i >= args.count || args[i].isEmpty) }
            .map { i, a in a.placeholder ?? "argument \(i + 1)" }
        var subtitle = [s.packageName, s.description].compactMap { $0 }.joined(separator: " · ")
        if s.mode == "inline" {
            refreshInlineIfStale(s, missing: missing)
            if let out = inline[s.name] { subtitle = out.line }
        }
        if !missing.isEmpty { subtitle = "Type /\(s.name) " + missing.map { "‹\($0)›" }.joined(separator: " ") }
        if !s.isExecutable { subtitle = "Not executable: choose Make Executable (chmod +x)" }

        let primary: Action
        if !s.isExecutable {
            primary = Action("Make Executable", icon: .symbol("lock.open")) { [weak self] in
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: s.url.path)
                self?.scannedStamp = nil
                return .stay
            }
        } else if !missing.isEmpty {
            primary = Action("Run Script", icon: .symbol("play")) { .hud("Needs \(missing.joined(separator: ", ")): type /\(s.name) then the value") }
        } else if s.needsConfirmation {
            primary = Action("Run Script", icon: .symbol("play")) { [unowned self] in .push(self.confirm(s, args)) }
        } else {
            primary = Action("Run Script", icon: .symbol("play")) { [unowned self] in await self.run(s, args) }
        }

        return Item(id: s.url.path, title: args.isEmpty ? s.title : "\(s.title)  \(args.joined(separator: " "))", subtitle: subtitle,
                    icon: s.icon, accessories: [.text("/\(s.name)")] + (s.isExecutable ? [] : [.pill("chmod +x", .orange)]),
                    primary: primary,
                    secondary: Action("Open Script", icon: .symbol("doc.text")) { NSWorkspace.shared.open(s.url); return .close },
                    more: [
                        Action("Show in Finder", icon: .symbol("folder"), shortcut: Shortcut("f", [.command, .shift])) {
                            NSWorkspace.shared.activateFileViewerSelecting([s.url])
                            return .close
                        },
                        Action("Copy Path", icon: .symbol("doc.on.doc"), shortcut: Shortcut("c", [.command, .shift])) { [weak self] in
                            self?.context.copy(s.url.path)
                            return .hud("Copied")
                        },
                    ])
    }

    // MARK: Running

    private func run(_ s: Script, _ args: [String]) async -> Outcome {
        let args = Self.encode(args, for: s.arguments)
        switch s.mode {
        case "silent":
            Task { [weak self] in
                let r = await Self.capture(s, args)
                let line = Self.lastLine(r.output)
                if !line.isEmpty { self?.context.showHUD(line) } else if r.status != 0 { self?.context.showHUD("\(s.title) failed (\(r.status))") }
            }
            return .close
        case "compact":
            let r = await Self.capture(s, args)
            let line = Self.lastLine(r.output)
            return .hud(line.isEmpty ? (r.status == 0 ? "\(s.title): done" : "\(s.title) failed (\(r.status))") : line)
        case "inline":
            let r = await Self.capture(s, args)
            inline[s.name] = (Self.firstLine(r.output), Date())
            return .stay
        default:
            return .push(stream(s, args))
        }
    }

    /// `@raycast.needsConfirmation true`: ask before running.
    private func confirm(_ s: Script, _ args: [String]) -> ListView {
        ListView(title: "Run “\(s.title)”?", icon: s.icon, placeholder: "Confirm…") { [weak self] q in
            guard let self else { return [] }
            let items = [
                Item(id: "run", title: "Run \(s.title)", icon: .symbol("play"),
                     primary: Action("Run Script", destructive: true) { await self.run(s, args) }),
                Item(id: "cancel", title: "Cancel", icon: .symbol("xmark"), primary: Action("Cancel") { .pop }),
            ]
            return [Section("Confirm", items.filter { Fuzzy.score(q.text, $0.title) != nil })]
        }
    }

    /// fullOutput mode: streams stdout and stderr into the detail area, like the Terminal extension.
    private func stream(_ s: Script, _ args: [String]) -> ListView {
        let detail = DetailModel(text: "", isRunning: true)
        let process = Self.process(s, args)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = Self.stripANSI(String(decoding: data, as: UTF8.self))
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

        return ListView(title: s.title, icon: s.icon, placeholder: "Output actions…", detail: detail) { [weak self] q in
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
                     primary: Action("Run Again") { .push(self.stream(s, args)) }),
                Item(id: "open", title: "Open Script", icon: .symbol("doc.text"),
                     primary: Action("Open Script") { NSWorkspace.shared.open(s.url); return .close }),
            ]
            return [Section(detail.isRunning ? "Running" : "Finished", items.filter { Fuzzy.score(q.text, $0.title) != nil })]
        }
    }

    /// Inline mode runs in the background at most every `refreshTime` (≥ 10 s) and fills the subtitle.
    private func refreshInlineIfStale(_ s: Script, missing: [String]) {
        guard s.isExecutable, missing.isEmpty, !inlineRunning.contains(s.name) else { return }
        if let last = inline[s.name], Date().timeIntervalSince(last.date) < s.refreshTime { return }
        inlineRunning.insert(s.name)
        Task { [weak self] in
            let r = await Self.capture(s, [])
            guard let self else { return }
            self.inlineRunning.remove(s.name)
            self.inline[s.name] = (Self.firstLine(r.output).isEmpty ? (r.status == 0 ? "No output" : "Failed (\(r.status))") : Self.firstLine(r.output), Date())
            self.context.refresh()
        }
    }

    private static func process(_ s: Script, _ args: [String]) -> Process {
        let p = Process()
        p.executableURL = s.url
        p.arguments = args
        p.currentDirectoryURL = s.directory
        p.standardInput = FileHandle.nullDevice
        // Apps launched from Finder get a minimal PATH; scripts expect Homebrew tools to resolve.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        return p
    }

    /// Runs to completion (60 s at most) and returns the combined output.
    private static func capture(_ s: Script, _ args: [String]) async -> (status: Int32, output: String) {
        let p = process(s, args)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try p.run() } catch {
                    cont.resume(returning: (-1, error.localizedDescription))
                    return
                }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    private static func lines(_ output: String) -> [String] {
        stripANSI(output).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func lastLine(_ output: String) -> String { lines(output).last ?? "" }
    static func firstLine(_ output: String) -> String { lines(output).first ?? "" }

    /// Raycast renders ANSI colours; here they are dropped.
    private static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    /// "a b c d" into 2 arguments → ["a", "b c d"].
    static func split(_ text: String, into count: Int) -> [String] {
        guard count > 0 else { return [] }
        return text.split(maxSplits: count - 1, whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func encode(_ args: [String], for specs: [Argument]) -> [String] {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return args.enumerated().map { i, a in
            i < specs.count && specs[i].percentEncoded == true ? a.addingPercentEncoding(withAllowedCharacters: allowed) ?? a : a
        }
    }

    // MARK: Scanning

    /// The folder's and its subfolders' modification dates change whenever a script is added, removed or renamed.
    private func folderStamp() -> Date? {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        var dates = [(try? folder.resourceValues(forKeys: keys))?.contentModificationDate]
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? [] {
            if let v = try? url.resourceValues(forKeys: keys), v.isDirectory == true { dates.append(v.contentModificationDate) }
        }
        return dates.compactMap { $0 }.max()
    }

    private func rescanIfChanged() {
        let stamp = folderStamp()
        guard stamp != scannedStamp || stamp == nil else { return }
        scannedStamp = stamp
        scripts = scan()
    }

    private func scan() -> [Script] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [Script] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) < 512_000,
                  let source = try? String(contentsOf: url, encoding: .utf8), let script = Self.parse(url, source) else { continue }
            found.append(script)
        }
        return found.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func parse(_ url: URL, _ source: String) -> Script? {
        let meta = metadata(source)
        guard let title = meta["title"], !title.isEmpty else { return nil }
        let dir = url.deletingLastPathComponent()
        let arguments = (1...3).compactMap { i in
            meta["argument\(i)"].flatMap { try? JSONDecoder().decode(Argument.self, from: Data($0.utf8)) }
        }
        var directory = dir
        if let path = meta["currentDirectoryPath"], !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            directory = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : dir.appendingPathComponent(expanded)
        }
        return Script(url: url, name: slug(url.deletingPathExtension().lastPathComponent), title: title,
                      mode: meta["mode"] ?? "fullOutput", packageName: meta["packageName"], description: meta["description"],
                      icon: icon(meta["icon"], relativeTo: dir), arguments: arguments,
                      needsConfirmation: meta["needsConfirmation"] == "true", directory: directory,
                      refreshTime: max(10, meta["refreshTime"].flatMap(duration) ?? 10),
                      isExecutable: FileManager.default.isExecutableFile(atPath: url.path))
    }

    /// `# @raycast.title Hello` / `// @raycast.title Hello` → ["title": "Hello"]
    static func metadata(_ source: String) -> [String: String] {
        var meta: [String: String] = [:]
        for raw in source.split(whereSeparator: \.isNewline).prefix(120) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.hasPrefix("--") { line.removeFirst(2) } else if line.hasPrefix("#") { line.removeFirst() } else { continue }
            line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("@raycast.") else { continue }
            let rest = line.dropFirst("@raycast.".count)
            guard let space = rest.firstIndex(where: \.isWhitespace) else { continue }
            meta[String(rest[..<space])] = rest[space...].trimmingCharacters(in: .whitespaces)
        }
        return meta
    }

    static func slug(_ name: String) -> String {
        let parts = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return parts.joined(separator: "-")
    }

    /// Emoji, an image path (relative to the script) or a URL (not fetched; falls back to a symbol).
    private static func icon(_ value: String?, relativeTo dir: URL) -> Icon {
        guard let value, !value.isEmpty else { return .symbol("scroll") }
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return .symbol("scroll") }
        if value.contains("/") || value.contains(".") {
            let expanded = (value as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : dir.appendingPathComponent(expanded)
            return NSImage(contentsOf: url).map { .image($0) } ?? .symbol("scroll")
        }
        return .text(value)
    }

    /// "10s", "5m", "1h", "1d" → seconds.
    private static func duration(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let n = Double(text.dropLast()) else { return nil }
        switch unit {
        case "s": return n
        case "m": return n * 60
        case "h": return n * 3600
        case "d": return n * 86400
        default: return nil
        }
    }

    /// A first-run example so the folder explains itself. A hidden marker keeps it from coming back once deleted.
    private func seedExampleIfEmpty() {
        let fm = FileManager.default
        let marker = folder.appendingPathComponent(".seeded")
        guard !fm.fileExists(atPath: marker.path) else { return }
        fm.createFile(atPath: marker.path, contents: Data())
        let entries = (try? fm.contentsOfDirectory(atPath: folder.path)).map { $0.filter { !$0.hasPrefix(".") } } ?? []
        guard entries.isEmpty else { return }
        let example = """
        #!/bin/bash

        # Required parameters:
        # @raycast.schemaVersion 1
        # @raycast.title Hello World
        # @raycast.mode fullOutput

        # Optional parameters:
        # @raycast.icon 👋
        # @raycast.packageName Examples
        # @raycast.description Prints a greeting. Type /hello-world and a name.
        # @raycast.argument1 { "type": "text", "placeholder": "Name", "optional": true }

        echo "Hello, ${1:-World}!"
        echo "Scripts from github.com/raycast/script-commands work here unchanged."

        """
        let url = folder.appendingPathComponent("hello-world.sh")
        fm.createFile(atPath: url.path, contents: Data(example.utf8), attributes: [.posixPermissions: 0o755])
    }
}
