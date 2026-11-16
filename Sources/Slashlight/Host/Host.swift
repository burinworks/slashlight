import AppKit
import SlashlightKit

/// Owns the extensions, the panel and the HUD. Everything UI-facing goes through here.
@MainActor
final class Host {
    static let shared = Host()

    private(set) var extensions: [Extension] = []
    /// Every extension, including turned-off ones (for the Settings window).
    private(set) var allExtensions: [Extension] = []
    private(set) var settings = Settings.load()
    lazy var model = PaletteModel(host: self)
    lazy var panel = PanelController(model: model)
    let hud = HUDController()

    /// The app that was in front when the panel opened.
    private(set) var previousApp: NSRunningApplication?

    func start() async {
        await loadExtensions()
        registerHotkeys()
    }

    func loadExtensions() async {
        for ext in extensions { await ext.deactivate() }
        settings = Settings.load()
        settings.applyAppearance()
        let builtIns = BuiltIns.all()
        allExtensions = builtIns + ExternalExtension.discover(in: Paths.extensions, reservedIDs: Set(builtIns.map(\.manifest.id)))
        extensions = allExtensions.filter { !settings.disabledExtensions.contains($0.manifest.id) }
        for ext in extensions {
            await ext.start(context: HostContext(id: ext.manifest.id, host: self))
        }
    }

    /// Every key Settings → Hotkeys shows, rebuilt with the global ones. The panel looks up its keys here.
    private(set) var hotkeyBindings: [HotkeyBinding] = []
    /// Global keys macOS refused, usually because another app already uses them.
    private(set) var failedHotkeys: Set<String> = []

    func registerHotkeys() {
        settings = Settings.load()
        HotKeyCenter.shared.unregisterAll()
        hotkeyBindings = HotkeyMap.bindings(host: self, settings: settings)
        failedHotkeys = []
        for b in hotkeyBindings where b.scope == .global && !DevSuite.isActive {
            guard let s = b.shortcut else { continue }
            if b.owner == "window-management" && !settings.windowManagementHotkeys { continue }
            // Never take ⌘C and the like from every app; macOS's own keys would never arrive anyway.
            if ReservedKeys.reason(s, scope: .global) != nil { failedHotkeys.insert(b.id); continue }
            if !HotKeyCenter.shared.register(s, handler: { b.run(s) }) { failedHotkeys.insert(b.id) }
        }
    }

    /// The panel's key for `pressed`: Slashlight's own first, then the open extension's.
    func panelHotkey(_ pressed: Shortcut, extensionID: String?) -> HotkeyBinding? {
        hotkeyBindings.first { $0.scope == .system && $0.shortcut == pressed }
            ?? hotkeyBindings.first { $0.scope == .local && $0.itemActionID == nil && $0.owner == extensionID && $0.shortcut == pressed }
    }

    /// The key an item action runs on: the user's choice from Settings → Hotkeys, else the action's own.
    func itemActionKey(_ action: Action, extensionID: String?) -> Shortcut? {
        guard let extensionID, let b = hotkeyBindings.first(where: { $0.owner == extensionID && $0.itemActionID == action.id })
        else { return action.shortcut }
        return b.shortcut
    }

    /// A local key of `extensionID`'s, for screens that handle keys themselves (the terminal, Insights).
    func localHotkey(_ pressed: Shortcut, extensionID: String) -> HotkeyBinding? {
        hotkeyBindings.first { $0.scope == .local && $0.itemActionID == nil && $0.owner == extensionID && $0.shortcut == pressed }
    }

    /// Runs an extension's hotkey action. A local one acts on the panel like any action; a global one opens the
    /// panel only when it pushes a screen.
    func runHotkey(_ action: HotkeyAction, pressed: Shortcut, extensionID: String) {
        Task {
            do {
                let outcome = try await action.run(pressed)
                if action.scope == .local {
                    model.apply(outcome, extensionID: extensionID)
                    return
                }
                switch outcome {
                case .close: if isVisible { hide() }
                case .stay, .pop: break
                case .push(let view):
                    show()
                    model.push(view, extensionID: extensionID)
                case .hud(let message):
                    hide()
                    showHUD(message)
                case .paste(let text): paste(text)
                }
            } catch {
                showHUD("⚠︎ \(error.localizedDescription)")
            }
        }
    }

    /// Saves settings from the Settings window and applies what changed.
    func update(_ change: (inout Settings) -> Void) {
        var s = Settings.load()
        change(&s)
        let extensionsChanged = s.disabledExtensions != settings.disabledExtensions
        s.save()
        settings = s
        s.applyAppearance()
        ClipboardExtension.shared?.apply(s)
        Updater.shared.apply(s)
        if extensionsChanged { Task { await reload() } } else { registerHotkeys() }
    }

    func reload() async {
        await loadExtensions()
        registerHotkeys()
    }

    // MARK: Panel

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show(extensionID: String? = nil) {
        if !isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
            for ext in extensions { ext.panelWillOpen() }
            model.reset()
            UsageStore.shared.panelOpened(extensionID: extensionID)
        }
        if let extensionID, let ext = extensions.first(where: { $0.manifest.id == extensionID }) {
            model.reset()
            model.open(ext)
        }
        panel.show()
    }

    func hide() {
        panel.hide()
        model.holdModifier = nil
    }

    func showHUD(_ message: String) { hud.show(message) }

    func paste(_ text: String) {
        copy(text)
        pasteClipboard()
    }

    /// Pastes what is on the clipboard now (all of its formats) into the app that was in front.
    func pasteClipboard() {
        hide()
        if NSRunningApplication.current.isActive { previousApp?.activate() }
        guard Permissions.isGranted(.accessibility) else {
            Permissions.request(.accessibility)
            showHUD("Copied — allow Accessibility to auto-paste")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Keyboard.pressPaste() }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func ext(_ id: String?) -> Extension? {
        guard let id else { return nil }
        return extensions.first { $0.manifest.id == id }
    }
}

@MainActor
final class HostContext: ExtensionContext {
    let id: String
    unowned let host: Host
    private let memory = MemoryStorage()
    private lazy var files = FileStorage(directory: supportDirectory)

    init(id: String, host: Host) {
        self.id = id
        self.host = host
    }

    func storage(_ kind: StorageKind) -> KeyValueStorage { kind == .ephemeral ? memory : files }

    var supportDirectory: URL {
        let url = Paths.support.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var frontmostApplication: NSRunningApplication? {
        host.isVisible ? host.previousApp : NSWorkspace.shared.frontmostApplication
    }

    func copy(_ text: String) { host.copy(text) }
    func showHUD(_ message: String) { host.showHUD(message) }
    func refresh() { if host.isVisible { host.model.refresh() } }
    func present(extensionID: String) { host.show(extensionID: extensionID) }
    func close() { host.hide() }
}
