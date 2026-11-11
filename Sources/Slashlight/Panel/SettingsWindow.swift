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
            w.title = "\(BuildInfo.name) Settings"
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
                LabeledContent("Background") {
                    HStack {
                        Text("See-through").font(.caption).foregroundStyle(.secondary)
                        Slider(value: model.binding(\.panelOpacity), in: 0.5...1)
                        Text("Solid").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Blur what's behind the panel", isOn: model.binding(\.panelBlur))
                PanelPreview().frame(maxWidth: .infinity)
            }
            Section {
                Toggle(isOn: model.binding(\.clipboardKeepHistory)) {
                    Text("Keep history after quitting")
                    Text("Encrypted on this Mac with a key in your Keychain. Copies from password managers are never saved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Forget entries after", selection: model.binding(\.clipboardForgetAfterDays)) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("Never").tag(0)
                }
                LabeledContent("History") {
                    Button("Clear History", role: .destructive) { ClipboardExtension.shared?.clearAll() }
                }
            } header: {
                Text("Clipboard History")
            } footer: {
                Text("Keeps up to 300 entries: text with its formatting, images and files.").font(.caption).foregroundStyle(.secondary)
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

/// Click, then press a key combination with at least one of ⌘ ⌥ ⌃. Esc or a click anywhere else cancels,
/// so picking a suggested hotkey in the welcome tour ends recording. Also used by the welcome tour.
struct HotkeyRecorder: View {
    @Binding var value: String
    var placeholder: String?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var clickMonitor: Any?
    /// When a click ended recording. The same click then reaches this button, which must not start again.
    @State private var stoppedByClick = Date.distantPast

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Text(recording ? "Press keys…" : placeholder ?? Shortcut(string: value)?.display ?? value)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
        }
        .onDisappear(perform: stop)
        // Another control set the hotkey (a suggested one was picked).
        .onChange(of: value) { _, _ in stop() }
    }

    private func toggle() {
        if recording { stop() } else if Date().timeIntervalSince(stoppedByClick) > 0.5 { start() }
    }

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
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            stoppedByClick = Date()
            stop()
            return event
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        monitor = nil
        clickMonitor = nil
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
                        if !granted {
                            Button("Reset") { Permissions.reset(p) }
                                .help(Permissions.staleHint)
                        }
                        Button(granted ? "Open System Settings" : "Grant Access") { Permissions.request(p) }
                    }
                }
            } footer: {
                Text("Status updates within a second of granting. \(Permissions.staleHint)")
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
            Text(BuildInfo.name).font(.title2.weight(.semibold))
            if let tag = BuildInfo.tag { BuildTag(text: tag) }
            Text("Version \(BuildInfo.fullVersion)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Open-source, keyboard-first launcher for macOS.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Show Welcome Tour") { OnboardingWindowController.shared.show() }
                Button("Reset Welcome Tour") { Install.resetOnboarding() }
                    .help("Shows the tour now and on every launch until you finish it")
            }
            .padding(.top, 6)
            Button("Uninstall \(BuildInfo.name)…", role: .destructive) { Install.confirmUninstall() }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// A small panel over a colorful backdrop, so the opacity and blur settings can be judged without opening the panel.
private struct PanelPreview: View {
    @ObservedObject var style = PanelStyle.shared

    var body: some View {
        ZStack {
            LinearGradient(colors: [.orange, .pink, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 18) { ForEach(0..<6) { _ in Circle().fill(.white.opacity(0.8)).frame(width: 18) } }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.text)
                    Text("Search…").foregroundStyle(Theme.secondary)
                    Spacer()
                }
                HStack(spacing: 8) {
                    IconView(icon: .symbol("square.grid.2x2"), size: 22)
                    Text("All Apps").foregroundStyle(Theme.text)
                    Spacer()
                }
                .padding(6)
                .background(Theme.selection, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .font(.system(size: 13))
            .padding(12)
            .frame(width: 260)
            .background(PanelBackground(style: style, blending: .withinWindow))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
        }
        .frame(height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
