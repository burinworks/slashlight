import AppKit
import SlashlightKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        Updater.shared.start(with: Host.shared.settings)
        Task {
            await Host.shared.start()
            _ = Host.shared.panel // build the panel up-front so the first open is instant
            if CommandLine.arguments.contains("--list-windows") {
                for w in await WindowSwitcherExtension.scanAllSpaces() {
                    print(w.onCurrentSpace ? "here " : "other", w.minimized ? "min" : "   ", w.appName, "—", w.title)
                }
                exit(0)
            }
            if let path = argument("--snapshot") { await snapshot(to: path); return }
            if CommandLine.arguments.contains("--settings") {
                SettingsWindowController.shared.show(tab: argument("--tab").flatMap(SettingsTab.init(rawValue:)))
                if let path = argument("--snapshot-settings") {
                    if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    SettingsWindowController.shared.snapshot(to: path)
                    exit(0)
                }
                return
            }
            if !CommandLine.arguments.contains("--background") { Host.shared.show() }
        }
    }

    private func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Debug aid: `Slashlight --snapshot out.png [--query text] [--open ext-id] [--enter] [--dark]` renders the panel and quits.
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
        if let session = TerminalManager.shared.sessions.last {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for line in session.view.visibleRowsText(0..<30) where !line.trimmingCharacters(in: .whitespaces).isEmpty { print("│ " + line) }
            print("state:", session.activity)
        }
        guard let view = host.panel.panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        exit(0)
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Slashlight")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Slashlight", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Open Config Folder", action: #selector(config), keyEquivalent: "").target = self
        if Updater.shared.isAvailable {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(Updater.checkForUpdates), keyEquivalent: "").target = Updater.shared
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Slashlight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func open() { Host.shared.show() }

    @objc private func settings() { SettingsWindowController.shared.show() }

    @objc private func config() { NSWorkspace.shared.open(Paths.support) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
