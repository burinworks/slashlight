import AppKit

/// The one base class every extension inherits — built-in or third-party.
///
/// An extension returns *data* (sections of items, each with actions); the host renders it,
/// so every extension gets the same look and keyboard behaviour for free:
///
/// - the first action of an item runs on ↵ / click,
/// - the second on ⌘↵ / ⌘-click,
/// - all of them are listed under ⌘K, and any with a `shortcut` also run on that key.
///
/// Minimal example:
/// ```swift
/// final class Hello: Extension {
///     override var manifest: Manifest { Manifest(id: "hello", title: "Hello", icon: .symbol("hand.wave")) }
///     override var triggers: [Trigger] { [.command("hello")] }
///     override func search(_ query: Query) async throws -> [Section] {
///         [Section("Greetings", [Item(id: "hi", title: "Say hi", icon: .symbol("face.smiling"),
///                                     primary: Action("Say hi") { .hud("Hi \(query.text)!") })])]
///     }
/// }
/// ```
@MainActor
open class Extension {
    public init() {}

    /// The host-provided services. Available from `activate(context:)` onwards.
    public private(set) var context: ExtensionContext!

    // MARK: Identity

    open var manifest: Manifest { fatalError("\(type(of: self)) must override `manifest`") }

    // MARK: How the user reaches it

    /// Where this extension shows up. See `Trigger`.
    open var triggers: [Trigger] { [] }

    /// macOS permissions this extension needs. The host asks for them only when the extension is used.
    open var permissions: [Permission] { [] }

    /// System-wide hotkeys that work even when the panel is closed.
    open var globalHotkeys: [GlobalHotkey] { [] }

    // MARK: Lifecycle

    /// Called by the host. Stores the context, then calls `activate(context:)`.
    public final func start(context: ExtensionContext) async {
        self.context = context
        await activate(context: context)
    }

    open func activate(context: ExtensionContext) async {}
    open func deactivate() async {}

    // MARK: Results

    /// Results for the current query. Called on every keystroke; the previous call is cancelled,
    /// so long-running work should check `Task.isCancelled` or use `try await Task.sleep` to debounce.
    open func search(_ query: Query) async throws -> [Section] { [] }

    /// The screen shown when the user opens this extension (from the dropdown, the root list or `/command`).
    /// Defaults to a searchable list backed by `search(_:)` with `query.mode == .scoped`.
    open func rootView() -> ListView? {
        ListView(title: manifest.title, icon: manifest.icon, placeholder: "Search \(manifest.title)…") { [unowned self] query in
            try await self.search(query)
        }
    }
}

public struct Manifest {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: Icon
    public var version: String
    public var author: String?

    public init(id: String, title: String, subtitle: String? = nil, icon: Icon, version: String = "1.0", author: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.version = version
        self.author = author
    }
}

public enum Trigger: Equatable {
    /// Contributes results when the user types plain text (apps, files…).
    case defaultSearch
    /// Takes over the bar when the text starts with this prefix, e.g. `>` for the terminal.
    /// `search` receives the text after the prefix with `mode == .prefix`.
    case prefix(String)
    /// Reachable as `/name`; opening it shows `rootView()`.
    case command(String)
    /// Contributes items to `/` command mode (`search` receives the text after `/` with `mode == .command`).
    case commands
}

public enum Permission: String, CaseIterable {
    case accessibility
    case screenRecording
    case automation
}

public struct GlobalHotkey {
    public var shortcut: Shortcut
    public var title: String
    public var run: @MainActor () -> Void

    public init(_ shortcut: Shortcut, title: String, run: @escaping @MainActor () -> Void) {
        self.shortcut = shortcut
        self.title = title
        self.run = run
    }
}
