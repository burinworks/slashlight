import AppKit
import SpotlightKit

/// Owns the extensions, the panel and the HUD. Everything UI-facing goes through here.
@MainActor
final class Host {
    static let shared = Host()

    private(set) var extensions: [Extension] = []
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
        extensions = BuiltIns.all() + ExternalExtension.discover(in: Paths.extensions)
        for ext in extensions {
            await ext.start(context: HostContext(id: ext.manifest.id, host: self))
        }
    }

    func registerHotkeys() {
        settings = Settings.load()
        HotKeyCenter.shared.unregisterAll()
        if let s = Shortcut(string: settings.hotkey) {
            HotKeyCenter.shared.register(s) { [weak self] in self?.toggle() }
        }
        for ext in extensions {
            if ext.manifest.id == "window-management" && !settings.windowManagementHotkeys { continue }
            for hk in ext.globalHotkeys {
                HotKeyCenter.shared.register(hk.shortcut) { hk.run() }
            }
        }
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
            model.reset()
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
