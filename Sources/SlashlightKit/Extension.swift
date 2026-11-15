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

    /// Actions the user can run with a key. Each lists in Settings → Hotkeys, where the user can record another
    /// key or clear it. Every extension with a screen also gets an "Open <title>" slot there, with no key by default.
    open var hotkeys: [HotkeyAction] { [] }

    // MARK: Lifecycle

    /// Called by the host. Stores the context, then calls `activate(context:)`.
    public final func start(context: ExtensionContext) async {
        self.context = context
        await activate(context: context)
    }

    open func activate(context: ExtensionContext) async {}
    open func deactivate() async {}

    /// Called each time the panel opens. Reload anything cached (app lists, window lists), then call
    /// `context.refresh()` if the visible results changed. Must return quickly: start slow work in a `Task`.
    open func panelWillOpen() {}

    // MARK: Results

    /// Results for the current query. Called on every keystroke; the previous call is cancelled,
    /// so long-running work should check `Task.isCancelled` or use `try await Task.sleep` to debounce.
    open func search(_ query: Query) async throws -> [Section] { [] }

    /// The screen shown when the user opens this extension by typing its name or picking it on the home list.
    /// Defaults to a searchable list backed by `search(_:)` with `query.mode == .scoped`.
    /// Return nil for an inline-only extension (the calculator): it adds results to the search but has no screen of its own.
    open func rootView() -> ListView? {
        ListView(title: manifest.title, icon: manifest.icon, placeholder: "Search \(manifest.title)…") { [unowned self] query in
            try await self.search(query)
        }
    }

    /// Rebuilds an item the user ran before, for the home screen's Recent section (`manifest.recents == .actions`).
    /// The default searches the extension for `title` and picks the item with this `id`.
    open func recentItem(id: String, title: String) async -> Item? {
        for text in [title, ""] {
            let sections = (try? await search(Query(text: text, mode: .scoped))) ?? []
            if let item = sections.lazy.flatMap(\.items).first(where: { $0.id == id }) { return item }
        }
        return nil
    }
}

public struct Manifest {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: Icon
    public var version: String
    public var author: String?
    /// What the home screen's Recent section shows after the user used this extension.
    public var recents: RecentsMode

    public init(id: String, title: String, subtitle: String? = nil, icon: Icon, version: String = "1.0", author: String? = nil,
                recents: RecentsMode = .wholeExtension) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.version = version
        self.author = author
        self.recents = recents
    }
}

/// How an extension appears in Recent on the home screen.
public enum RecentsMode: String, Sendable {
    /// The items the user ran ("Left Half", "/my-ip", Safari). Use when each item is a command of its own.
    case actions
    /// The extension itself (Clipboard History). Use when items are content, not commands.
    case wholeExtension = "extension"
    /// Never listed (the calculator, web search).
    case hidden = "none"
}

public enum Trigger: Equatable {
    /// Contributes results when the user types plain text (apps, files…).
    case defaultSearch
    /// Takes over the bar when the text starts with this prefix, e.g. `>` for the terminal.
    /// `search` receives the text after the prefix with `mode == .prefix`.
    case prefix(String)
    /// Another name the extension is found by when typed in the search ("switch" for Window Switcher).
    /// Extensions open by name, not by `/name`: `/` lists commands only.
    case command(String)
    /// Contributes items to `/` command mode (`search` receives the text after `/` with `mode == .command`).
    case commands
}

public enum Permission: String, CaseIterable {
    case accessibility
    case screenRecording
    case automation
}

/// An action an extension offers to run with a key (`Extension.hotkeys`).
public struct HotkeyAction {
    public enum Scope: String, Sendable, CaseIterable {
        /// Works anywhere on the Mac while Slashlight runs, panel open or not. The key needs ⌘, ⌥ or ⌃.
        case global
        /// Works only while one of this extension's screens is open in the panel.
        case local
    }

    /// Stable within the extension; the user's key is saved under it.
    public var id: String
    public var title: String
    public var scope: Scope
    /// The key until the user changes it; nil leaves the action without one.
    public var defaultShortcut: Shortcut?
    /// Shown next to it in Settings; the extension's icon when nil.
    public var icon: Icon?
    /// Gets the key that was pressed, which is the user's choice when they changed it. A global action's
    /// outcome applies to the panel only when it asks for it: `.push` opens the panel, `.hud` and `.paste` work as
    /// usual, the rest do nothing.
    public var run: @MainActor (Shortcut) async throws -> Outcome

    public init(id: String, title: String, scope: Scope, default shortcut: Shortcut? = nil, icon: Icon? = nil,
                run: @escaping @MainActor (Shortcut) async throws -> Outcome) {
        self.icon = icon
        self.id = id
        self.title = title
        self.scope = scope
        self.defaultShortcut = shortcut
        self.run = run
    }
}
