import AppKit
import SpotlightKit

/// Adapter for an extension that runs as its own process and speaks `Wire` JSON over stdin/stdout.
///
/// Installed as `~/Library/Application Support/MySpotlight/Extensions/<name>/manifest.json`:
/// ```json
/// { "id": "hello", "title": "Hello", "icon": "sf:hand.wave",
///   "triggers": ["commands", "command:hello"], "exec": ["./hello-extension"] }
/// ```
@MainActor
final class ExternalExtension: Extension {
    struct FileManifest: Codable {
        var id: String
        var title: String
        var subtitle: String?
        var icon: String?
        var version: String?
        var author: String?
        var triggers: [String]
        /// Executable and arguments; relative paths resolve against the extension folder.
        var exec: [String]
    }

    private let file: FileManifest
    private let directory: URL
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Wire.Message, Error>] = [:]
    /// Detail areas of pushed screens that are still open, by view id. Dropped when the screen is.
    private var details: [String: DetailModel] = [:]

    struct ProtocolError: LocalizedError {
        var errorDescription: String?
    }

    init(file: FileManifest, directory: URL) {
        self.file = file
        self.directory = directory
    }

    static func discover(in root: URL) -> [Extension] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { return nil }
            do {
                return ExternalExtension(file: try JSONDecoder().decode(FileManifest.self, from: data), directory: dir)
            } catch {
                NSLog("MySpotlight: bad manifest in \(dir.path): \(error)")
                return nil
            }
        }
    }

    override var manifest: Manifest {
        Manifest(id: file.id, title: file.title, subtitle: file.subtitle, icon: Wire.decodeIcon(file.icon),
                 version: file.version ?? "1.0", author: file.author)
    }

    override var triggers: [Trigger] { file.triggers.compactMap(Wire.decodeTrigger) }

    override func deactivate() async {
        if process?.isRunning == true { send(Wire.Request(type: "shutdown", id: 0)) }
        process?.terminate()
        process = nil
    }

    override func search(_ query: Query) async throws -> [Section] {
        try await search(query, view: nil)
    }

    /// `view` is the pushed screen the query belongs to; `nil` for the root screen (v1).
    private func search(_ query: Query, view: String?) async throws -> [Section] {
        let reply = try await request(Wire.Request(type: "search", id: 0, query: query.text,
                                                    mode: Wire.modeString(query.mode), filter: query.filter, view: view))
        return (reply.sections ?? []).map { s in
            Section(s.title, s.items.map { item($0, view: view) })
        }
    }

    private func item(_ w: Wire.WItem, view: String?) -> Item {
        let actions = w.actions.map { a in
            Action(a.title, id: a.id, shortcut: a.shortcut.flatMap(Shortcut.init(string:)), destructive: a.destructive ?? false) { [weak self] in
                guard let self else { return .close }
                let reply = try await self.request(Wire.Request(type: "run", id: 0, itemId: w.id, actionId: a.id, view: view))
                return self.outcome(reply.outcome)
            }
        }
        var item = Item(id: w.id, title: w.title, subtitle: w.subtitle, icon: Wire.decodeIcon(w.icon),
                        accessories: (w.accessories ?? []).map(Wire.decode),
                        primary: actions.first ?? Action("Close") { .close })
        item.actions = actions.isEmpty ? item.actions : actions
        return item
    }

    private func outcome(_ o: Wire.WOutcome?) -> Outcome {
        switch o?.type {
        case "stay": return .stay
        case "pop": return .pop
        case "hud": return .hud(o?.value ?? "")
        case "paste": return .paste(o?.value ?? "")
        case "push":
            guard let v = o?.view else { return .stay }
            return .push(listView(v))
        default: return .close
        }
    }

    private func listView(_ v: Wire.WView) -> ListView {
        // The lease lives as long as the screen's search closure, i.e. as long as the panel keeps the screen.
        let lease = ViewLease(id: v.id, owner: self)
        return ListView(title: v.title, icon: v.icon.map(Wire.decodeIcon) ?? manifest.icon,
                        placeholder: v.placeholder ?? "Search \(v.title)…", layout: Wire.decodeLayout(v.layout),
                        filters: v.filters ?? [], initialText: v.initialText ?? "", initialSelection: v.initialSelection ?? 0,
                        detail: details[v.id]) { [weak self] query in
            guard let self else { return [] }
            return try await self.search(query, view: lease.id)
        }
    }

    /// The panel dropped a pushed screen: let the extension free it.
    fileprivate func dispose(view id: String) {
        details.removeValue(forKey: id)
        if process?.isRunning == true { send(Wire.Request(type: "dispose", id: 0, view: id)) }
    }

    // MARK: Process plumbing

    private func request(_ req: Wire.Request) async throws -> Wire.Message {
        try launchIfNeeded()
        var req = req
        req.id = nextID
        req.supportDirectory = context.supportDirectory.path
        nextID += 1
        let id = req.id
        let reply: Wire.Message = try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            send(req)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                MainActor.assumeIsolated {
                    self?.pending.removeValue(forKey: id)?.resume(throwing: ProtocolError(errorDescription: "\(self?.file.title ?? "Extension") timed out"))
                }
            }
        }
        if reply.type == "error" { throw ProtocolError(errorDescription: reply.message ?? "extension error") }
        return reply
    }

    private func send(_ req: Wire.Request) {
        guard var data = try? JSONEncoder().encode(req) else { return }
        data.append(0x0A)
        try? stdin?.write(contentsOf: data)
    }

    private func launchIfNeeded() throws {
        if process?.isRunning == true { return }
        guard let exe = file.exec.first else { throw ProtocolError(errorDescription: "manifest has empty exec") }
        let p = Process()
        p.executableURL = exe.hasPrefix("/") ? URL(fileURLWithPath: exe) : directory.appendingPathComponent(exe)
        p.arguments = Array(file.exec.dropFirst())
        p.currentDirectoryURL = directory
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.standardError
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(chunk) } }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let waiting = self.pending
                    self.pending.removeAll()
                    waiting.values.forEach { $0.resume(throwing: ProtocolError(errorDescription: "\(self.file.title) exited")) }
                }
            }
        }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        buffer.removeAll()
    }

    private func receive(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let msg = try? JSONDecoder().decode(Wire.Message.self, from: line) else {
                NSLog("MySpotlight: [\(file.id)] bad message: \(String(decoding: line, as: UTF8.self))")
                continue
            }
            // Create a pushed screen's detail area now, so `detail` messages right behind the outcome have a target.
            if let v = msg.outcome?.view, let text = v.detail {
                details[v.id] = DetailModel(text: text, isRunning: v.running ?? false)
            }
            if let id = msg.id, let cont = pending.removeValue(forKey: id) {
                cont.resume(returning: msg)
                continue
            }
            switch msg.type {
            case "refresh": context.refresh()
            case "detail":
                guard let detail = details[msg.view ?? ""] else { break }
                if let text = msg.text { detail.text = msg.append == true ? detail.text + text : text }
                if let running = msg.running { detail.isRunning = running }
            case "hud": context.showHUD(msg.message ?? "")
            case "outcome" where msg.outcome?.type == "close": context.close()
            default: break
            }
        }
    }
}

/// Captured by a pushed screen's search closure; tells the extension when the screen is gone.
private final class ViewLease {
    let id: String
    weak var owner: ExternalExtension?

    init(id: String, owner: ExternalExtension) {
        self.id = id
        self.owner = owner
    }

    deinit {
        let id = id, owner = owner
        DispatchQueue.main.async { MainActor.assumeIsolated { owner?.dispose(view: id) } }
    }
}
