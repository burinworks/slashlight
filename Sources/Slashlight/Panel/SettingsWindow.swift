import AppKit
import SlashlightKit
import SwiftUI

/// The Settings window (⌘, in the panel, or the menu bar icon → Settings…).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var model: SettingsModel?
    private var pendingTab: SettingsTab?

    func show(tab: SettingsTab? = nil) {
        pendingTab = tab
        if let tab { model?.tab = tab }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Slashlight Settings"
            w.isReleasedWhenClosed = false
            w.delegate = self
            let model = SettingsModel(host: Host.shared)
            if let pending = pendingTab { model.tab = pending }
            self.model = model
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Debug aid for `--settings --snapshot-settings out.png`.
    func snapshot(to path: String) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the view so its timers stop; it is rebuilt with fresh state next time.
        window = nil
        model = nil
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    unowned let host: Host
    @Published var settings: Settings
    @Published var permissions: [Permission: Bool] = [:]
    @Published var loginItem = LoginItem.isEnabled
    @Published var extensionsVersion = 0
    @Published var tab = SettingsTab.general
    private var timer: Timer?

    init(host: Host) {
        self.host = host
        settings = host.settings
        refreshPermissions()
        // Permissions are granted in System Settings; poll so the window reflects them without reopening.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    deinit { timer?.invalidate() }

    func refreshPermissions() {
        var p: [Permission: Bool] = [:]
        for perm in [Permission.accessibility, .screenRecording] { p[perm] = Permissions.isGranted(perm) }
        if p != permissions { permissions = p }
    }

    func update(_ change: @escaping (inout Settings) -> Void) {
        let before = settings.disabledExtensions
        host.update(change)
        settings = host.settings
        guard settings.disabledExtensions != before else { return }
        Task {
            // host.update reloads extensions in the background; redraw the list once that is done.
            try? await Task.sleep(nanoseconds: 300_000_000)
            extensionsVersion += 1
        }
    }

    func binding<T>(_ keyPath: WritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] },
                set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    func isEnabled(_ id: String) -> Binding<Bool> {
        Binding(get: { !self.settings.disabledExtensions.contains(id) },
                set: { on in self.update { s in
                    s.disabledExtensions.removeAll { $0 == id }
                    if !on { s.disabledExtensions.append(id) }
                } })
    }

    func toggleLoginItem() {
        do { try LoginItem.toggle() } catch { host.showHUD("Launch at login: \(error.localizedDescription)") }
        loginItem = LoginItem.isEnabled
    }

    func reloadExtensions() {
        Task {
            await host.reload()
            extensionsVersion += 1
        }
    }
}

enum SettingsTab: String, CaseIterable {
    case general = "General", extensions = "Extensions", permissions = "Permissions", about = "About"

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .extensions: return "puzzlepiece.extension"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button { model.tab = tab } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.symbol).font(.system(size: 18))
                            Text(tab.rawValue).font(.system(size: 11))
                        }
                        .frame(width: 84, height: 48)
                        .foregroundStyle(model.tab == tab ? Color.accentColor : .secondary)
                        .background(model.tab == tab ? Color.primary.opacity(0.08) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
            Divider()
            Group {
                switch model.tab {
                case .general: GeneralSettings(model: model)
                case .extensions: ExtensionsSettings(model: model)
                case .permissions: PermissionsSettings(model: model)
                case .about: AboutSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: 560)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Hotkeys") {
                LabeledContent("Open Slashlight") { HotkeyRecorder(value: model.binding(\.hotkey)) }
                LabeledContent("Switch window") { HotkeyRecorder(value: model.binding(\.windowSwitcherHotkey)) }
                Toggle(isOn: model.binding(\.windowManagementHotkeys)) {
                    Text("Window layout hotkeys")
                    Text("⌃⌥ + arrows, ↵, C, ⌫, D F G E T, U I J K").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Appearance") {
                Picker("Theme", selection: model.binding(\.appearance)) {
                    Text("Match System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section("Startup") {
                Toggle(isOn: Binding(get: { model.loginItem }, set: { _ in model.toggleLoginItem() })) {
                    Text("Launch at login")
                    Text("Works when running the bundled Slashlight.app").font(.caption).foregroundStyle(.secondary)
                }
            }
            UpdateSettings(model: model)
            Section("Files") {
                LabeledContent("Config folder") {
                    Button("Open in Finder") { NSWorkspace.shared.open(Paths.support) }
                }
                LabeledContent("settings.json") {
                    Button("Edit") { NSWorkspace.shared.open(Paths.settings) }
                }
                LabeledContent("Commands") {
                    Button("Edit commands.json") {
                        NSWorkspace.shared.open(Paths.support.appendingPathComponent("commands/commands.json"))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then press a key combination with at least one of ⌘ ⌥ ⌃. Esc cancels.
private struct HotkeyRecorder: View {
    @Binding var value: String
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Text(recording ? "Press keys…" : Shortcut(string: value)?.display ?? value)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        // Carbon hotkeys swallow their keys before the app sees them, so pause them while recording.
        HotKeyCenter.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil } // esc
            let mods = Shortcut.Modifiers(event.modifierFlags)
            guard !mods.isDisjoint(with: [.command, .option, .control]) else { NSSound.beep(); return nil }
            value = Shortcut(KeyCodes.key(for: event), mods).string
            stop()
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        Host.shared.registerHotkeys()
    }
}

// MARK: Extensions

private struct ExtensionsSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(model.host.allExtensions.map(\.manifest), id: \.id) { m in
                    let external = model.host.allExtensions.first { $0.manifest.id == m.id } is ExternalExtension
                    Toggle(isOn: model.isEnabled(m.id)) {
                        HStack(spacing: 10) {
                            IconView(icon: m.icon, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.title)
                                Text([m.subtitle, external ? "external" : "built-in", "v\(m.version)"].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(m.id == "apps")
                }
            } header: {
                Text("Installed")
            } footer: {
                Text("External extensions live in the Extensions folder, one subfolder with a manifest.json each.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Extensions folder") {
                    Button("Open in Finder") {
                        try? FileManager.default.createDirectory(at: Paths.extensions, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Paths.extensions)
                    }
                }
                LabeledContent("After adding or updating one") {
                    Button("Reload Extensions", action: model.reloadExtensions)
                }
            }
        }
        .formStyle(.grouped)
        .id(model.extensionsVersion)
    }
}

// MARK: Permissions

private struct PermissionsSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach([Permission.accessibility, .screenRecording], id: \.self) { p in
                    let granted = model.permissions[p] ?? false
                    HStack(spacing: 10) {
                        Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(granted ? .green : .orange)
                            .font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Permissions.title(p))
                            Text(Permissions.reason(p)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(granted ? "Open System Settings" : "Grant Access") { Permissions.request(p) }
                    }
                }
            } footer: {
                Text("The app is ad-hoc signed, so macOS may ask again after each rebuild. If a granted permission does not take effect, remove Slashlight from the list in System Settings and add it again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: About

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("Slashlight").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Open-source, keyboard-first launcher for macOS.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
