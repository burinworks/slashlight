import AppKit
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

        var label: String {
            switch self {
            case .global: return "Global"
            case .local: return "In extension"
            case .system: return "In Slashlight"
            }
        }

        var help: String {
            switch self {
            case .global: return "Works anywhere on your Mac while Slashlight runs"
            case .local: return "Works only while this extension is open in the panel"
            case .system: return "Works anywhere in the panel, in every extension"
            }
        }
    }

    /// `HotkeyMap.slashlight` or an extension id.
    let owner: String
    let ownerTitle: String
    let action: String
    let title: String
    let scope: Scope
    let defaultShortcut: Shortcut?
    /// The key in effect: the user's choice, else the default. Nil when there is none.
    let shortcut: Shortcut?
    /// Open Slashlight can't be cleared: without it the panel is reachable only from the menu bar.
    var canClear = true
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
        case .back: return "Back (closes the panel on the main search)"
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

    /// Every key, in the order Settings shows them: Slashlight first, then extensions by title.
    static func bindings(host: Host, settings: Settings) -> [HotkeyBinding] {
        var out: [HotkeyBinding] = []
        let open = Shortcut(string: settings.hotkey)
        out.append(HotkeyBinding(owner: slashlight, ownerTitle: "Slashlight", action: "open", title: "Open Slashlight",
                                 scope: .global, defaultShortcut: Shortcut("space", .option), shortcut: open, canClear: false,
                                 run: { [weak host] _ in host?.toggle() }))
        for key in SystemHotkey.allCases {
            let id = "\(slashlight)/\(key.rawValue)"
            out.append(HotkeyBinding(owner: slashlight, ownerTitle: "Slashlight", action: key.rawValue, title: key.title,
                                     scope: .system, defaultShortcut: key.defaultShortcut,
                                     shortcut: shortcut(id, default: key.defaultShortcut, in: settings),
                                     run: { [weak host] _ in if let host { key.run(host.model) } }))
        }
        let sorted = host.extensions.sorted { $0.manifest.title.localizedCaseInsensitiveCompare($1.manifest.title) == .orderedAscending }
        for ext in sorted {
            let owner = ext.manifest.id, title = ext.manifest.title
            if ext.rootView() != nil {
                out.append(HotkeyBinding(owner: owner, ownerTitle: title, action: "open", title: "Open \(title)", scope: .global,
                                         defaultShortcut: nil, shortcut: shortcut("\(owner)/open", default: nil, in: settings),
                                         run: { [weak host] _ in host?.show(extensionID: owner) }))
            }
            for action in ext.hotkeys where action.id != "open" {
                let scope: HotkeyBinding.Scope = action.scope == .global ? .global : .local
                out.append(HotkeyBinding(owner: owner, ownerTitle: title, action: action.id, title: action.title, scope: scope,
                                         defaultShortcut: action.defaultShortcut,
                                         shortcut: shortcut("\(owner)/\(action.id)", default: action.defaultShortcut, in: settings),
                                         run: { [weak host] pressed in host?.runHotkey(action, pressed: pressed, extensionID: owner) }))
            }
        }
        return out
    }

    /// Other keys set to the same combination that can be live at the same time.
    static func conflicts(of binding: HotkeyBinding, in all: [HotkeyBinding]) -> [HotkeyBinding] {
        guard let s = binding.shortcut else { return [] }
        return all.filter { $0.id != binding.id && $0.shortcut == s && $0.overlaps(binding) }
    }

    /// A global key must not take over typing in other apps, so it needs ⌘, ⌥ or ⌃. Keys used inside the
    /// panel may also be Esc, Tab, or a function key on its own.
    static func isAllowed(_ s: Shortcut, scope: HotkeyBinding.Scope) -> Bool {
        if !s.modifiers.isDisjoint(with: [.command, .option, .control]) { return true }
        guard scope != .global else { return false }
        return s.key == "escape" || s.key == "tab" || s.key.hasPrefix("f") && s.key.count > 1
    }
}
