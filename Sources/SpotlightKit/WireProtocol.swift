import Foundation

/// JSON messages exchanged with out-of-process extensions, one object per line over stdin/stdout.
/// Spec: docs/extension-protocol.md.
public enum Wire {
    public static let version = 2

    /// Host → extension.
    public struct Request: Codable {
        /// "hello" | "search" | "run" | "dispose" | "shutdown"
        public var type: String
        public var id: Int
        public var query: String?
        /// "default" | "command" | "prefix" | "scoped"
        public var mode: String?
        public var filter: String?
        public var itemId: String?
        public var actionId: String?
        public var supportDirectory: String?
        /// v2: the pushed screen a `search` / `run` / `dispose` belongs to. Absent for the root screen.
        public var view: String?

        public init(type: String, id: Int, query: String? = nil, mode: String? = nil, filter: String? = nil,
                    itemId: String? = nil, actionId: String? = nil, supportDirectory: String? = nil, view: String? = nil) {
            self.type = type; self.id = id; self.query = query; self.mode = mode; self.filter = filter
            self.itemId = itemId; self.actionId = actionId; self.supportDirectory = supportDirectory; self.view = view
        }
    }

    /// Extension → host. `id` echoes the request; messages without `id` are unsolicited.
    public struct Message: Codable {
        /// "hello" | "results" | "outcome" | "error" | "refresh" | "hud" | "detail"
        public var type: String
        public var id: Int?
        public var version: Int?
        public var sections: [WSection]?
        public var outcome: WOutcome?
        public var message: String?
        /// v2: the pushed screen a `refresh` / `detail` targets.
        public var view: String?
        /// v2 `detail`: new text for the screen's detail area; appended when `append` is true.
        public var text: String?
        public var append: Bool?
        /// v2 `detail`: shows or hides the screen's running indicator.
        public var running: Bool?

        public init(type: String, id: Int? = nil, version: Int? = nil, sections: [WSection]? = nil,
                    outcome: WOutcome? = nil, message: String? = nil, view: String? = nil,
                    text: String? = nil, append: Bool? = nil, running: Bool? = nil) {
            self.type = type; self.id = id; self.version = version; self.sections = sections
            self.outcome = outcome; self.message = message; self.view = view
            self.text = text; self.append = append; self.running = running
        }
    }

    public struct WSection: Codable {
        public var title: String
        public var items: [WItem]
        public init(title: String, items: [WItem]) { self.title = title; self.items = items }
    }

    public struct WItem: Codable {
        public var id: String
        public var title: String
        public var subtitle: String?
        /// "sf:<symbol>", "file:<path>" or "text:<emoji>"
        public var icon: String?
        public var accessories: [WAccessory]?
        public var actions: [WAction]
        public init(id: String, title: String, subtitle: String?, icon: String?, accessories: [WAccessory]?, actions: [WAction]) {
            self.id = id; self.title = title; self.subtitle = subtitle; self.icon = icon
            self.accessories = accessories; self.actions = actions
        }
    }

    public struct WAction: Codable {
        public var id: String
        public var title: String
        /// "cmd+shift+p"
        public var shortcut: String?
        public var destructive: Bool?
        public init(id: String, title: String, shortcut: String?, destructive: Bool?) {
            self.id = id; self.title = title; self.shortcut = shortcut; self.destructive = destructive
        }
    }

    public struct WAccessory: Codable {
        /// "pill" | "text" | "keycap"
        public var type: String
        public var value: String
        public var tint: Tint?
        public init(type: String, value: String, tint: Tint? = nil) { self.type = type; self.value = value; self.tint = tint }
    }

    public struct WOutcome: Codable {
        /// "close" | "stay" | "push" | "pop" | "hud" | "paste"
        public var type: String
        public var value: String?
        /// The screen to open, for `push`.
        public var view: WView?
        public init(type: String, value: String? = nil, view: WView? = nil) { self.type = type; self.value = value; self.view = view }
    }

    /// v2: a sub-screen opened by a `push` outcome. Its searches and runs carry `id` as `view`.
    public struct WView: Codable {
        public var id: String
        public var title: String
        public var icon: String?
        public var placeholder: String?
        /// "list" | "grid:<columns>"
        public var layout: String?
        public var filters: [String]?
        public var initialText: String?
        public var initialSelection: Int?
        /// Present (even empty) when the screen has a detail area; the initial text.
        public var detail: String?
        public var running: Bool?
        public init(id: String, title: String, icon: String? = nil, placeholder: String? = nil, layout: String? = nil,
                    filters: [String]? = nil, initialText: String? = nil, initialSelection: Int? = nil,
                    detail: String? = nil, running: Bool? = nil) {
            self.id = id; self.title = title; self.icon = icon; self.placeholder = placeholder; self.layout = layout
            self.filters = filters; self.initialText = initialText; self.initialSelection = initialSelection
            self.detail = detail; self.running = running
        }
    }

    // MARK: Conversions shared by host and SDK

    public static func encode(_ icon: Icon) -> String? {
        switch icon {
        case .symbol(let s): return "sf:\(s)"
        case .file(let p): return "file:\(p)"
        case .text(let t): return "text:\(t)"
        case .image: return nil
        }
    }

    public static func decodeIcon(_ s: String?) -> Icon {
        guard let s else { return .symbol("puzzlepiece.extension") }
        if s.hasPrefix("sf:") { return .symbol(String(s.dropFirst(3))) }
        if s.hasPrefix("file:") { return .file(String(s.dropFirst(5))) }
        if s.hasPrefix("text:") { return .text(String(s.dropFirst(5))) }
        return .symbol(s)
    }

    public static func encode(_ a: Accessory) -> WAccessory {
        switch a {
        case .pill(let t, let tint): return WAccessory(type: "pill", value: t, tint: tint)
        case .text(let t): return WAccessory(type: "text", value: t)
        case .keycap(let s): return WAccessory(type: "keycap", value: s.string)
        }
    }

    public static func decode(_ a: WAccessory) -> Accessory {
        switch a.type {
        case "pill": return .pill(a.value, a.tint ?? .blue)
        case "keycap": return Shortcut(string: a.value).map { .keycap($0) } ?? .text(a.value)
        default: return .text(a.value)
        }
    }

    public static func encode(_ layout: ListView.Layout) -> String {
        switch layout {
        case .list: return "list"
        case .grid(let columns): return "grid:\(columns)"
        }
    }

    public static func decodeLayout(_ s: String?) -> ListView.Layout {
        guard let s, s.hasPrefix("grid") else { return .list }
        return .grid(columns: Int(s.split(separator: ":").last ?? "") ?? 3)
    }

    public static func modeString(_ mode: Query.Mode) -> String {
        switch mode {
        case .default: return "default"
        case .command: return "command"
        case .prefix: return "prefix"
        case .scoped: return "scoped"
        }
    }

    public static func decodeTrigger(_ s: String) -> Trigger? {
        if s == "default" { return .defaultSearch }
        if s == "commands" { return .commands }
        if s.hasPrefix("prefix:") { return .prefix(String(s.dropFirst(7))) }
        if s.hasPrefix("command:") { return .command(String(s.dropFirst(8))) }
        return nil
    }
}
