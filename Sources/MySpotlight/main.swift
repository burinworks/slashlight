import AppKit
import SpotlightKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        Task {
            await Host.shared.start()
            _ = Host.shared.panel // build the panel up-front so the first open is instant
            if let path = argument("--snapshot") { await snapshot(to: path); return }
            if !CommandLine.arguments.contains("--background") { Host.shared.show() }
        }
    }

    private func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Debug aid: `MySpotlight --snapshot out.png [--query text] [--open ext-id] [--enter] [--dark]` renders the panel and quits.
    private func snapshot(to path: String) async {
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        let host = Host.shared
        host.show(extensionID: argument("--open"))
        if let q = argument("--query") { host.model.text = q }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if CommandLine.arguments.contains("--enter") {
            host.model.runPrimary()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        guard let view = host.panel.panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        exit(0)
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "My Spotlight")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open My Spotlight", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Open Config Folder", action: #selector(config), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit My Spotlight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func open() { Host.shared.show() }

    @objc private func settings() {
        Host.shared.show()
        Host.shared.model.openSettings()
    }

    @objc private func config() { NSWorkspace.shared.open(Paths.support) }
}

enum SettingsScreen {
    @MainActor
    static func make(host: Host) -> ListView {
        ListView(title: "Settings", icon: .symbol("gearshape"), placeholder: "Search settings…") { q in
            let perms = Permission.allCases.filter { $0 != .automation }.map { p -> Item in
                let ok = Permissions.isGranted(p)
                return Item(id: "perm-\(p.rawValue)", title: Permissions.title(p), subtitle: Permissions.reason(p),
                            icon: .symbol(p == .accessibility ? "accessibility" : "rectangle.dashed.badge.record"),
                            accessories: [ok ? .pill("Granted", .green) : .pill("Missing", .orange)],
                            primary: Action(ok ? "Open System Settings" : "Grant Access") { Permissions.request(p); return .close })
            }
            let s = host.settings
            let general = [
                Item(id: "hotkey", title: "Open hotkey", subtitle: "\(Shortcut(string: s.hotkey)?.display ?? s.hotkey) · edit settings.json to change",
                     icon: .symbol("keyboard"),
                     primary: Action("Edit settings.json") { NSWorkspace.shared.open(Paths.settings); return .close },
                     secondary: Action("Reload Settings") { host.registerHotkeys(); return .hud("Settings reloaded") }),
                Item(id: "login", title: "Launch at login", subtitle: "Requires running the bundled .app",
                     icon: .symbol("power"), accessories: [LoginItem.isEnabled ? .pill("On", .green) : .pill("Off", .gray)],
                     primary: Action("Toggle") { try LoginItem.toggle(); return .stay }),
                Item(id: "folder", title: "Open config folder", subtitle: Paths.support.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                     icon: .symbol("folder"),
                     primary: Action("Open in Finder") { NSWorkspace.shared.open(Paths.support); return .close }),
                Item(id: "reload", title: "Reload extensions", subtitle: "\(host.extensions.count) loaded · external ones live in Extensions/",
                     icon: .symbol("arrow.clockwise"),
                     primary: Action("Reload") { await host.reload(); return .hud("Extensions reloaded") }),
                Item(id: "quit", title: "Quit My Spotlight", icon: .symbol("xmark.circle"),
                     primary: Action("Quit", destructive: true) { NSApp.terminate(nil); return .close }),
            ]
            let installed = host.extensions.map { ext in
                Item(id: "ext-\(ext.manifest.id)", title: ext.manifest.title,
                     subtitle: [ext.manifest.subtitle, "v\(ext.manifest.version)", ext is ExternalExtension ? "external" : "built-in"]
                        .compactMap { $0 }.joined(separator: " · "),
                     icon: ext.manifest.icon,
                     primary: Action("Open") { [weak ext] in ext?.rootView().map { .push($0) } ?? .stay })
            }
            func filter(_ items: [Item]) -> [Item] { items.filter { Fuzzy.score(q.text, [$0.title, $0.subtitle ?? ""]) != nil } }
            return [Section("Permissions", filter(perms)), Section("General", filter(general)), Section("Extensions", filter(installed))]
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
