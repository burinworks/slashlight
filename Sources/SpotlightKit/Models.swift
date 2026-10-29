import AppKit
import Combine

// MARK: - Query

public struct Query {
    public enum Mode: Equatable {
        /// Plain text typed into the bar.
        case `default`
        /// Text after a leading `/`.
        case command
        /// Text after this extension's prefix trigger.
        case prefix(String)
        /// Inside the extension's own screen.
        case scoped
    }

    public var text: String
    public var mode: Mode
    /// The active Tab filter, if the current screen declares `filters`.
    public var filter: String?

    public init(text: String, mode: Mode, filter: String? = nil) {
        self.text = text
        self.mode = mode
        self.filter = filter
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
}

// MARK: - Results

public struct Section {
    public var title: String
    public var items: [Item]

    public init(_ title: String, _ items: [Item]) {
        self.title = title
        self.items = items
    }
}

public struct Item: Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: Icon
    public var accessories: [Accessory]
    /// `actions[0]` runs on ↵, `actions[1]` on ⌘↵, all are listed under ⌘K.
    public var actions: [Action]

    public init(id: String, title: String, subtitle: String? = nil, icon: Icon = .symbol("circle"),
                accessories: [Accessory] = [], primary: Action, secondary: Action? = nil, more: [Action] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.accessories = accessories
        self.actions = [primary] + (secondary.map { [$0] } ?? []) + more
    }

    public var primary: Action? { actions.first }
    public var secondary: Action? { actions.count > 1 ? actions[1] : nil }
}

public struct Action {
    public var id: String
    public var title: String
    public var icon: Icon?
    /// Extra shortcut. Must include ⌘, ⌃ or ⌥ so it does not clash with typing.
    /// ↵ and ⌘↵ are assigned automatically to the first two actions.
    public var shortcut: Shortcut?
    public var isDestructive: Bool
    public var run: @MainActor () async throws -> Outcome

    public init(_ title: String, id: String? = nil, icon: Icon? = nil, shortcut: Shortcut? = nil,
                destructive: Bool = false, run: @escaping @MainActor () async throws -> Outcome) {
        self.id = id ?? title.lowercased().replacingOccurrences(of: " ", with: "-")
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.isDestructive = destructive
        self.run = run
    }
}

/// What the host does after an action ran.
public enum Outcome {
    /// Hide the panel.
    case close
    /// Keep the panel open and re-run the search.
    case stay
    /// Navigate into a sub-screen. ⌫ on an empty bar comes back.
    case push(ListView)
    /// Go back one screen.
    case pop
    /// Hide the panel and show a short toast.
    case hud(String)
    /// Hide the panel, put the text on the clipboard and press ⌘V in the frontmost app.
    case paste(String)
}

public enum Icon {
    /// SF Symbol name.
    case symbol(String)
    /// Finder icon of the file or app at this path.
    case file(String)
    case image(NSImage)
    /// A short string (emoji, letter).
    case text(String)
}

public enum Accessory {
    case pill(String, Tint = .blue)
    case text(String)
    case keycap(Shortcut)
}

public enum Tint: String, Codable {
    case blue, green, orange, red, gray
}

// MARK: - Shortcut

public struct Shortcut: Hashable {
    public struct Modifiers: OptionSet, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// A single lowercase character, or one of: return, tab, space, delete, escape, left, right, up, down.
    public var key: String
    public var modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    public static let primary = Shortcut("return")
    public static let secondary = Shortcut("return", .command)

    /// "⌃⌥⌘⇧K"-style label, in the order macOS menus use.
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Shortcut.keySymbols[key, default: key.uppercased()]
    }

    static let keySymbols: [String: String] = [
        "return": "↵", "tab": "⇥", "space": "Space", "delete": "⌫", "escape": "esc",
        "left": "←", "right": "→", "up": "↑", "down": "↓",
    ]

    /// Parses "cmd+shift+p", "ctrl+opt+left".
    public init?(string: String) {
        var mods: Modifiers = []
        var key: String?
        for part in string.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default: key = part
            }
        }
        guard let key else { return nil }
        self.init(key, mods)
    }

    public var string: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }
}

// MARK: - Screens

/// A screen pushed onto the panel: a searchable list, optionally with a live text area above it.
@MainActor
public final class ListView {
    public enum Layout: Equatable {
        case list
        /// Large tiles (window thumbnails). ← → move by one, ↑ ↓ by a row.
        case grid(columns: Int)
    }

    public var title: String
    public var icon: Icon
    public var placeholder: String
    public var layout: Layout
    /// Tab cycles through these; the active one arrives as `query.filter`.
    public var filters: [String]
    /// Text pre-filled in the bar when the screen opens.
    public var initialText: String
    /// Row selected when the screen opens.
    public var initialSelection: Int
    /// Live text shown above the list (terminal output, previews).
    public var detail: DetailModel?
    public var search: @MainActor (Query) async throws -> [Section]

    public init(title: String, icon: Icon = .symbol("list.bullet"), placeholder: String = "Search…",
                layout: Layout = .list, filters: [String] = [], initialText: String = "", initialSelection: Int = 0,
                detail: DetailModel? = nil, search: @escaping @MainActor (Query) async throws -> [Section]) {
        self.title = title
        self.icon = icon
        self.placeholder = placeholder
        self.layout = layout
        self.filters = filters
        self.initialText = initialText
        self.initialSelection = initialSelection
        self.detail = detail
        self.search = search
    }
}

@MainActor
public final class DetailModel: ObservableObject {
    @Published public var text: String
    @Published public var isRunning: Bool
    public var monospaced: Bool

    public init(text: String = "", isRunning: Bool = false, monospaced: Bool = true) {
        self.text = text
        self.isRunning = isRunning
        self.monospaced = monospaced
    }
}
