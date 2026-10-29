import AppKit
import Combine
@_exported import SpotlightKit

/// Runs a `SpotlightKit.Extension` as a separate process: reads JSON requests from stdin,
/// writes JSON replies to stdout (one object per line). Log with `ExtensionRunner.log`, never `print`.
///
/// ```swift
/// ExtensionRunner.run { MyExtension() }
/// ```
public enum ExtensionRunner {
    /// Call from `main.swift`. Never returns; the process exits when the host closes stdin.
    public static func run(_ make: @escaping @MainActor () -> Extension) -> Never {
        let host = MainActor.assumeIsolated { StdioHost(ext: make()) }
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                guard let data = line.data(using: .utf8),
                      let request = try? JSONDecoder().decode(Wire.Request.self, from: data) else {
                    log("ignored malformed line: \(line)")
                    continue
                }
                Task { @MainActor in await host.handle(request) }
            }
            exit(0) // stdin closed: the host is gone.
        }
        MainActor.assumeIsolated { _ = NSApplication.shared.setActivationPolicy(.prohibited) }
        RunLoop.main.run()
        exit(0)
    }

    public static func log(_ message: String) {
        FileHandle.standardError.write(Data("[\(ProcessInfo.processInfo.processName)] \(message)\n".utf8))
    }
}

@MainActor
final class StdioHost: ExtensionContext {
    let ext: Extension
    private var started = false
    private var items: [String: Item] = [:]
    /// Screens returned as `Outcome.push`, most recently used last. The host disposes them when it drops a screen.
    private var views: [String: PushedView] = [:]
    private var viewOrder: [String] = []
    private var nextViewID = 1
    private static let maxViews = 32
    private var persistent: FileStorage?
    private let memory = MemoryStorage()
    private var support = FileManager.default.temporaryDirectory

    init(ext: Extension) { self.ext = ext }

    func handle(_ req: Wire.Request) async {
        if let dir = req.supportDirectory { support = URL(fileURLWithPath: dir) }
        if !started {
            started = true
            await ext.start(context: self)
        }
        switch req.type {
        case "hello":
            send(Wire.Message(type: "hello", id: req.id, version: Wire.version))
        case "search":
            let mode: Query.Mode = switch req.mode {
            case "command": .command
            case "prefix": .prefix("")
            case "scoped": .scoped
            default: .default
            }
            let query = Query(text: req.query ?? "", mode: mode, filter: req.filter)
            do {
                if let viewID = req.view {
                    guard let pushed = touch(viewID) else { return expired(req) }
                    let sections = try await pushed.view.search(query)
                    send(Wire.Message(type: "results", id: req.id, sections: sections.map { encode($0, into: pushed) }))
                } else {
                    let sections = try await ext.search(query)
                    send(Wire.Message(type: "results", id: req.id, sections: sections.map { encode($0, into: nil) }))
                }
            } catch {
                send(Wire.Message(type: "error", id: req.id, message: "\(error)"))
            }
        case "run":
            var known = items
            if let viewID = req.view {
                guard let pushed = touch(viewID) else { return expired(req) }
                known = pushed.items
            }
            guard let item = known[req.itemId ?? ""],
                  let action = item.actions.first(where: { $0.id == req.actionId }) else {
                send(Wire.Message(type: "error", id: req.id, message: "unknown item or action"))
                return
            }
            do {
                let outcome = try await action.run()
                send(Wire.Message(type: "outcome", id: req.id, outcome: encode(outcome)))
            } catch {
                send(Wire.Message(type: "error", id: req.id, message: "\(error)"))
            }
        case "dispose":
            if let viewID = req.view { forget(viewID) }
        case "shutdown":
            await ext.deactivate()
            exit(0)
        default:
            send(Wire.Message(type: "error", id: req.id, message: "unknown request type \(req.type)"))
        }
    }

    private func encode(_ section: Section, into pushed: PushedView?) -> Wire.WSection {
        Wire.WSection(title: section.title, items: section.items.map { item in
            if let pushed { pushed.items[item.id] = item } else { items[item.id] = item }
            return Wire.WItem(
                id: item.id, title: item.title, subtitle: item.subtitle, icon: Wire.encode(item.icon),
                accessories: item.accessories.map(Wire.encode),
                actions: item.actions.map { Wire.WAction(id: $0.id, title: $0.title, shortcut: $0.shortcut?.string, destructive: $0.isDestructive) })
        })
    }

    private func encode(_ outcome: Outcome) -> Wire.WOutcome {
        switch outcome {
        case .close: return .init(type: "close")
        case .stay: return .init(type: "stay")
        case .pop: return .init(type: "pop")
        case .hud(let s): return .init(type: "hud", value: s)
        case .paste(let s): return .init(type: "paste", value: s)
        case .push(let view): return .init(type: "push", view: register(view))
        }
    }

    // MARK: Pushed screens

    private func register(_ view: ListView) -> Wire.WView {
        let id = "v\(nextViewID)"
        nextViewID += 1
        let pushed = PushedView(view: view)
        views[id] = pushed
        viewOrder.append(id)
        while viewOrder.count > Self.maxViews { forget(viewOrder[0]) }
        if let detail = view.detail {
            pushed.sentText = detail.text
            // `@Published` emits before the property changes, so read the new value from the sink.
            pushed.observers.append(detail.$text.dropFirst().sink { [weak self, weak pushed] text in
                MainActor.assumeIsolated {
                    guard let self, let pushed else { return }
                    let old = pushed.sentText
                    pushed.sentText = text
                    if !old.isEmpty, text.hasPrefix(old) {
                        self.send(Wire.Message(type: "detail", view: id, text: String(text.dropFirst(old.count)), append: true))
                    } else {
                        self.send(Wire.Message(type: "detail", view: id, text: text))
                    }
                }
            })
            pushed.observers.append(detail.$isRunning.dropFirst().removeDuplicates().sink { [weak self] running in
                MainActor.assumeIsolated { self?.send(Wire.Message(type: "detail", view: id, running: running)) }
            })
        }
        return Wire.WView(id: id, title: view.title, icon: Wire.encode(view.icon), placeholder: view.placeholder,
                          layout: Wire.encode(view.layout), filters: view.filters.isEmpty ? nil : view.filters,
                          initialText: view.initialText.isEmpty ? nil : view.initialText,
                          initialSelection: view.initialSelection == 0 ? nil : view.initialSelection,
                          detail: view.detail?.text, running: view.detail?.isRunning)
    }

    /// Marks the screen as recently used.
    private func touch(_ id: String) -> PushedView? {
        guard let pushed = views[id] else { return nil }
        viewOrder.removeAll { $0 == id }
        viewOrder.append(id)
        return pushed
    }

    private func forget(_ id: String) {
        views.removeValue(forKey: id)
        viewOrder.removeAll { $0 == id }
    }

    private func expired(_ req: Wire.Request) {
        send(Wire.Message(type: "error", id: req.id, message: "screen \(req.view ?? "") is no longer open"))
    }

    private func send(_ message: Wire.Message) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    // MARK: ExtensionContext

    func storage(_ kind: StorageKind) -> KeyValueStorage {
        switch kind {
        case .ephemeral: return memory
        case .persistent:
            if persistent == nil { persistent = FileStorage(directory: supportDirectory) }
            return persistent!
        }
    }

    var supportDirectory: URL { support }
    var frontmostApplication: NSRunningApplication? { NSWorkspace.shared.frontmostApplication }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func showHUD(_ message: String) { send(Wire.Message(type: "hud", message: message)) }
    func refresh() { send(Wire.Message(type: "refresh")) }
    func present(extensionID: String) { ExtensionRunner.log("present(extensionID:) is not supported over protocol v1") }
    func close() { send(Wire.Message(type: "outcome", outcome: .init(type: "close"))) }
}

/// A `ListView` the extension pushed, with the items its last searches returned (for `run`).
@MainActor
final class PushedView {
    let view: ListView
    var items: [String: Item] = [:]
    var observers: [AnyCancellable] = []
    /// Detail text the host already has; changes are sent as appends when possible.
    var sentText = ""

    init(view: ListView) { self.view = view }
}
