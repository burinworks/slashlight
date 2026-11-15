import AppKit
import Carbon.HIToolbox
import SlashlightKit

/// One key in Settings → Hotkeys: Slashlight's own, an extension's "Open" slot, or an action an extension offers.
struct HotkeyBinding: Identifiable {
    enum Scope: String {
        /// Anywhere on the Mac while Slashlight runs.
        case global
        /// Only while one of the owning extension's screens is open in the panel.
        case local
        /// Anywhere in the panel, in every extension.
        case system

        var help: String {
            switch self {
            case .global: return "Global: works anywhere on your Mac while Slashlight runs"
            case .local: return "In this extension: works only while it is open in the panel"
            case .system: return "In Slashlight: works on every screen of the panel"
            }
        }
    }

    /// Where Settings lists the key: by what it does, not by who offers it.
    enum Group: Hashable {
        case slashlight, openExtensions, commands, windows
        case other(String)

        var title: String {
            switch self {
            case .slashlight: return "Slashlight"
            case .openExtensions: return "Open Extensions"
            case .commands: return "Commands & Scripts"
            case .windows: return "Windows"
            case .other(let title): return title
            }
        }

        var order: Int {
            switch self {
            case .slashlight: return 0
            case .openExtensions: return 1
            case .commands: return 2
            case .windows: return 3
            case .other: return 4
            }
        }
    }

    /// `HotkeyMap.slashlight` or an extension id.
    let owner: String
    let ownerTitle: String
    let action: String
    let title: String
    let scope: Scope
    let group: Group
    let icon: Icon?
    let defaultShortcut: Shortcut?
    /// The key in effect: the user's choice, else the default. Nil when there is none.
    let shortcut: Shortcut?
    /// Back is always Esc.
    var isEditable = true
    /// Open Slashlight is set in Settings → General, not in the Hotkeys list.
    var isListed = true
    let run: @MainActor (Shortcut) -> Void

    var id: String { "\(owner)/\(action)" }
    var isDefault: Bool { shortcut == defaultShortcut }

    /// Whether the two keys could both be live at the same moment.
    func overlaps(_ other: HotkeyBinding) -> Bool {
        if scope == .global || other.scope == .global { return true }
        if scope == .local && other.scope == .local { return owner == other.owner }
        return true
    }
}

/// The panel's own keys. They work in every list; screens with a text editor or terminal keep their own Esc.
enum SystemHotkey: String, CaseIterable {
    case back, actions, home, settings, terminal

    var title: String {
        switch self {
        case .back: return "Back, or close the panel"
        case .actions: return "Show actions"
        case .home: return "Back to the main search"
        case .settings: return "Open Settings"
        case .terminal: return "Go to the last terminal tab"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .back: return Shortcut("escape")
        case .actions: return Shortcut("k", .command)
        case .home: return Shortcut("e", .command)
        case .settings: return Shortcut(",", .command)
        case .terminal: return Shortcut("tab", .control)
        }
    }

    var symbol: String {
        switch self {
        case .back: return "arrow.uturn.backward"
        case .actions: return "command"
        case .home: return "house"
        case .settings: return "gearshape"
        case .terminal: return "terminal"
        }
    }

    @MainActor
    func run(_ model: PaletteModel) {
        switch self {
        case .back: model.back()
        case .actions: model.showActions()
        case .home: model.goHome()
        case .settings: model.openSettings()
        case .terminal:
            if let s = TerminalManager.shared.lastShown ?? TerminalManager.shared.sessions.last { model.showTerminal(s) }
        }
    }
}

@MainActor
enum HotkeyMap {
    static let slashlight = "slashlight"

    /// The key in effect for `id`: what the user recorded ("" = cleared), else the default.
    static func shortcut(_ id: String, default d: Shortcut?, in settings: Settings) -> Shortcut? {
        guard let saved = settings.hotkeys[id] else { return d }
        return saved.isEmpty ? nil : Shortcut(string: saved)
    }

    private static func group(owner: String, action: String, title: String) -> HotkeyBinding.Group {
        if action == "open" { return .openExtensions }
        switch owner {
        case "commands": return .commands
        case "window-management", "window-switcher": return .windows
        default: return .other(title)
        }
    }

    /// Every key, grouped and in the order Settings shows them.
    static func bindings(host: Host, settings: Settings) -> [HotkeyBinding] {
        var out: [HotkeyBinding] = []
        out.append(HotkeyBinding(owner: slashlight, ownerTitle: "Slashlight", action: "open", title: "Open Slashlight",
                                 scope: .global, group: .slashlight, icon: nil, defaultShortcut: Shortcut("space", .option),
                                 shortcut: Shortcut(string: settings.hotkey), isListed: false,
                                 run: { [weak host] _ in host?.toggle() }))
        for key in SystemHotkey.allCases {
            let id = "\(slashlight)/\(key.rawValue)"
            let fixed = key == .back
            out.append(HotkeyBinding(owner: slashlight, ownerTitle: "Slashlight", action: key.rawValue, title: key.title,
                                     scope: .system, group: .slashlight, icon: .symbol(key.symbol),
                                     defaultShortcut: key.defaultShortcut,
                                     shortcut: fixed ? key.defaultShortcut : shortcut(id, default: key.defaultShortcut, in: settings),
                                     isEditable: !fixed, isListed: !fixed,
                                     run: { [weak host] _ in if let host { key.run(host.model) } }))
        }
        let sorted = host.extensions.sorted { $0.manifest.title.localizedCaseInsensitiveCompare($1.manifest.title) == .orderedAscending }
        for ext in sorted {
            let owner = ext.manifest.id, title = ext.manifest.title
            if ext.rootView() != nil {
                out.append(HotkeyBinding(owner: owner, ownerTitle: title, action: "open", title: "Open \(title)", scope: .global,
                                         group: .openExtensions, icon: ext.manifest.icon,
                                         defaultShortcut: nil, shortcut: shortcut("\(owner)/open", default: nil, in: settings),
                                         run: { [weak host] _ in host?.show(extensionID: owner) }))
            }
            for action in ext.hotkeys where action.id != "open" {
                let scope: HotkeyBinding.Scope = action.scope == .global ? .global : .local
                out.append(HotkeyBinding(owner: owner, ownerTitle: title, action: action.id, title: action.title, scope: scope,
                                         group: group(owner: owner, action: action.id, title: title),
                                         icon: action.icon ?? ext.manifest.icon, defaultShortcut: action.defaultShortcut,
                                         shortcut: shortcut("\(owner)/\(action.id)", default: action.defaultShortcut, in: settings),
                                         run: { [weak host] pressed in host?.runHotkey(action, pressed: pressed, extensionID: owner) }))
            }
        }
        // Stable: within a group, the order above.
        return out.enumerated().sorted { a, b in
            a.element.group.order != b.element.group.order ? a.element.group.order < b.element.group.order : a.offset < b.offset
        }.map(\.element)
    }

    /// Other keys set to the same combination that can be live at the same time.
    static func conflicts(of binding: HotkeyBinding, in all: [HotkeyBinding]) -> [HotkeyBinding] {
        guard let s = binding.shortcut else { return [] }
        return all.filter { $0.id != binding.id && $0.shortcut == s && $0.overlaps(binding) }
    }

    /// A global key must not take over typing in other apps, so it needs ⌘, ⌥ or ⌃. Keys used inside the
    /// panel may also be Tab or a function key on its own. Esc is always Back.
    static func isAllowed(_ s: Shortcut, scope: HotkeyBinding.Scope) -> Bool {
        if !s.modifiers.isDisjoint(with: [.command, .option, .control]) { return true }
        guard scope != .global else { return false }
        return s.key == "tab" || s.key.hasPrefix("f") && s.key.count > 1
    }
}

/// Keys Slashlight won't take, because macOS or every app already gives them a meaning.
@MainActor
enum ReservedKeys {
    /// What ⌘C and friends mean in every app. A global key here would stop working in all of them.
    static let standard: [Shortcut: String] = {
        let c: Shortcut.Modifiers = .command
        var out: [Shortcut: String] = [
            Shortcut("c", c): "Copy", Shortcut("v", c): "Paste", Shortcut("x", c): "Cut", Shortcut("a", c): "Select All",
            Shortcut("z", c): "Undo", Shortcut("z", [.command, .shift]): "Redo", Shortcut("v", [.command, .option, .shift]): "Paste and Match Style",
            Shortcut("q", c): "Quit", Shortcut("w", c): "Close Window", Shortcut("h", c): "Hide",
            Shortcut("h", [.command, .option]): "Hide Others", Shortcut("m", c): "Minimize", Shortcut("n", c): "New",
            Shortcut("o", c): "Open", Shortcut("s", c): "Save", Shortcut("s", [.command, .shift]): "Save As",
            Shortcut("p", c): "Print", Shortcut("f", c): "Find", Shortcut("g", c): "Find Next", Shortcut("t", c): "New Tab",
            Shortcut("r", c): "Reload", Shortcut(",", c): "Settings", Shortcut("tab", c): "Switch Apps",
            Shortcut("`", c): "Switch Windows", Shortcut("escape", [.command, .option]): "Force Quit",
            Shortcut("q", [.command, .control]): "Lock Screen", Shortcut("q", [.command, .shift]): "Log Out",
            Shortcut("f", [.command, .control]): "Full Screen", Shortcut("space", [.command, .control]): "Emoji & Symbols",
            Shortcut("delete", c): "Delete", Shortcut("left", c): "Line Start", Shortcut("right", c): "Line End",
            Shortcut("up", c): "Top", Shortcut("down", c): "Bottom",
        ]
        return out
    }()

    /// The ones the search field itself needs, so no key inside the panel can take them either.
    static let editing: Set<Shortcut> = [
        Shortcut("c", .command), Shortcut("v", .command), Shortcut("x", .command), Shortcut("a", .command),
        Shortcut("z", .command), Shortcut("z", [.command, .shift]),
    ]

    /// Shortcuts macOS itself handles (System Settings → Keyboard → Keyboard Shortcuts) and has turned on:
    /// Spotlight, screenshots, Mission Control, input sources. Keys macOS takes never reach an app.
    static var macOS: [Shortcut: String] {
        if let cached, Date().timeIntervalSince(cached.date) < 5 { return cached.keys }
        let keys = readMacOS()
        cached = (Date(), keys)
        return keys
    }
    private static var cached: (date: Date, keys: [Shortcut: String])?

    /// Why `s` can't be used as a `scope` key, or nil when it can.
    static func reason(_ s: Shortcut, scope: HotkeyBinding.Scope) -> String? {
        if let name = macOS[s] { return "macOS uses \(s.display) for \(name)" }
        return standardReason(s, scope: scope)
    }

    /// The same, leaving out this Mac's own settings: what an extension's manifest is checked against.
    static func standardReason(_ s: Shortcut, scope: HotkeyBinding.Scope) -> String? {
        if s == Shortcut("escape") { return "esc always goes back" }
        if scope == .global, let name = standard[s] { return "\(s.display) is \(name) in every app" }
        if scope != .global, editing.contains(s), let name = standard[s] { return "\(s.display) is \(name) in the search field" }
        return nil
    }

    private static func readMacOS() -> [Shortcut: String] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let list = array?.takeRetainedValue() as? [[String: Any]] else { return [:] }
        let names = namesFromPreferences()
        var out: [Shortcut: String] = [:]
        for entry in list {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let mods = entry[kHISymbolicHotKeyModifiers as String] as? Int,
                  let s = shortcut(keyCode: code, carbon: mods) else { continue }
            out[s] = names[s] ?? defaultNames[s] ?? "a system shortcut"
        }
        return out
    }

    private static func shortcut(keyCode: Int, carbon mods: Int) -> Shortcut? {
        guard let key = KeyCodes.named.first(where: { $0.value == keyCode })?.key
                ?? KeyCodes.letters.first(where: { $0.value == keyCode })?.key else { return nil }
        var m: Shortcut.Modifiers = []
        if mods & cmdKey != 0 { m.insert(.command) }
        if mods & shiftKey != 0 { m.insert(.shift) }
        if mods & optionKey != 0 { m.insert(.option) }
        if mods & controlKey != 0 { m.insert(.control) }
        return Shortcut(key, m)
    }

    /// The Keyboard Shortcuts pane saves the ones you changed by number; these are the numbers we can name.
    private static let idNames: [Int: String] = [
        27: "Move focus to next window", 28: "Screenshot", 29: "Screenshot to clipboard", 30: "Screenshot of an area",
        31: "Area screenshot to clipboard", 32: "Mission Control", 33: "Application windows", 36: "Show Desktop",
        52: "Dock hiding", 60: "Previous input source", 61: "Next input source", 64: "Spotlight", 65: "Finder search",
        79: "Move left a space", 81: "Move right a space", 98: "Help menu", 162: "Accessibility shortcuts",
        184: "Screenshot options",
    ]

    private static let defaultNames: [Shortcut: String] = [
        Shortcut("space", .command): "Spotlight", Shortcut("space", [.command, .option]): "Finder search",
        Shortcut("3", [.command, .shift]): "Screenshot", Shortcut("4", [.command, .shift]): "Screenshot of an area",
        Shortcut("5", [.command, .shift]): "Screenshot options", Shortcut("space", .control): "Previous input source",
        Shortcut("space", [.control, .option]): "Next input source", Shortcut("up", .control): "Mission Control",
        Shortcut("down", .control): "Application windows", Shortcut("left", .control): "Move left a space",
        Shortcut("right", .control): "Move right a space", Shortcut("d", [.command, .option]): "Dock hiding",
    ]

    private static func namesFromPreferences() -> [Shortcut: String] {
        guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") else { return [:] }
        var out: [Shortcut: String] = [:]
        for (id, value) in all {
            guard let name = Int(id).flatMap({ idNames[$0] }), let entry = value as? [String: Any],
                  let params = (entry["value"] as? [String: Any])?["parameters"] as? [Int], params.count == 3 else { continue }
            let flags = NSEvent.ModifierFlags(rawValue: UInt(params[2]))
            var carbon = 0
            if flags.contains(.command) { carbon |= cmdKey }
            if flags.contains(.shift) { carbon |= shiftKey }
            if flags.contains(.option) { carbon |= optionKey }
            if flags.contains(.control) { carbon |= controlKey }
            if let s = shortcut(keyCode: params[1], carbon: carbon) { out[s] = name }
        }
        return out
    }
}
