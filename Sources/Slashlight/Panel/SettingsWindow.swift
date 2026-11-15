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
    private var pendingFilter: String?

    func show(tab: SettingsTab? = nil, hotkeyFilter: String? = nil) {
        pendingTab = tab
        pendingFilter = hotkeyFilter
        if let tab { model?.tab = tab }
        if let hotkeyFilter { model?.hotkeyFilter = hotkeyFilter }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "\(BuildInfo.name) Settings"
            w.isReleasedWhenClosed = false
            w.delegate = self
            let model = SettingsModel(host: Host.shared)
            if let pending = pendingTab { model.tab = pending }
            if let pendingFilter { model.hotkeyFilter = pendingFilter }
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
    /// The Hotkeys tab's search, so "Set Hotkey…" on a command can open the tab on that command.
    @Published var hotkeyFilter = ""
    /// For the ⌘Space choice: whether Spotlight still has it.
    @Published var spotlightOwnsCommandSpace = SpotlightShortcut.ownsCommandSpace
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
        let spotlight = SpotlightShortcut.ownsCommandSpace
        if spotlight != spotlightOwnsCommandSpace {
            spotlightOwnsCommandSpace = spotlight
            // ⌘Space was skipped while Spotlight had it; take it now (or let it go).
            host.registerHotkeys()
        }
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

    // MARK: Hotkeys

    /// Every key, from the current settings.
    var hotkeys: [HotkeyBinding] { HotkeyMap.bindings(host: host, settings: settings) }

    /// Saves `value` ("cmd+k", or "" for none) for `binding`. A key equal to the default is stored as no change.
    func setHotkey(_ binding: HotkeyBinding, _ value: String) {
        guard binding.isEditable else { return }
        update { s in
            if binding.id == "\(HotkeyMap.slashlight)/open" {
                if !value.isEmpty { s.hotkey = value }
            } else if value == (binding.defaultShortcut?.string ?? "") {
                s.hotkeys.removeValue(forKey: binding.id)
            } else {
                s.hotkeys[binding.id] = value
            }
        }
    }

    func resetHotkey(_ binding: HotkeyBinding) { setHotkey(binding, binding.defaultShortcut?.string ?? "") }

    /// Leaves Open Slashlight alone: that one lives in General.
    func resetAllHotkeys() {
        update { $0.hotkeys = [:] }
    }

    func reloadExtensions() {
        Task {
            await host.reload()
            extensionsVersion += 1
        }
    }
}

enum SettingsTab: String, CaseIterable {
    case general = "General", hotkeys = "Hotkeys", extensions = "Extensions", permissions = "Permissions", about = "About"

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .hotkeys: return "keyboard"
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
                case .hotkeys: HotkeysSettings(model: model)
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
            Section {
                OpenHotkeyPicker(model: model)
            } header: {
                Text("Open Slashlight")
            } footer: {
                if model.settings.hotkey == "cmd+space" && model.spotlightOwnsCommandSpace {
                    HStack(spacing: 8) {
                        Label("Spotlight still uses ⌘Space. Turn it off in Keyboard Shortcuts → Spotlight.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Keyboard Shortcuts", action: SpotlightShortcut.openKeyboardShortcuts).controlSize(.small)
                    }
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
    /// Which keys it accepts: global ones need ⌘, ⌥ or ⌃ (see `HotkeyMap.isAllowed`).
    var scope: HotkeyBinding.Scope = .global
    /// ⌫ while recording removes the key.
    var canClear = false
    /// Shows "esc cancel" next to the button while recording.
    var showsHint = false
    @State private var recording = false
    @State private var monitor: Any?
    @State private var clickMonitor: Any?
    /// When a click ended recording. The same click then reaches this button, which must not start again.
    @State private var stoppedByClick = Date.distantPast
    /// Why the last key pressed was refused (⌘C is Copy…); shown under the button for a moment.
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Button(action: toggle) {
                Text(recording ? "Press keys…" : placeholder ?? Shortcut(string: value)?.display ?? (value.isEmpty ? "Record" : value))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(!recording && value.isEmpty && placeholder == nil ? .secondary : .primary)
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            .popover(isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } }), arrowEdge: .bottom) {
                Label(refusal ?? "", systemImage: "nosign").font(.callout).padding(10)
            }
            // Always laid out, only shown while recording, so the button never moves.
            if showsHint {
                RecorderHint(canClear: canClear && !value.isEmpty).opacity(recording ? 1 : 0)
            }
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
            let mods = Shortcut.Modifiers(event.modifierFlags)
            let key = KeyCodes.key(for: event)
            if key == "escape" && mods.isEmpty { stop(); return nil }
            if key == "delete" && mods.isEmpty && canClear {
                value = ""
                stop()
                return nil
            }
            let shortcut = Shortcut(key, mods)
            guard HotkeyMap.isAllowed(shortcut, scope: scope) else {
                refuse(scope == .global ? "Add ⌘, ⌥ or ⌃" : "Add ⌘, ⌥ or ⌃, or use Tab or F1–F12")
                return nil
            }
            if let reason = ReservedKeys.reason(shortcut, scope: scope) {
                refuse(reason)
                return nil
            }
            value = shortcut.string
            stop()
            return nil
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            stoppedByClick = Date()
            stop()
            return event
        }
    }

    /// Keeps recording, so the next key can be tried straight away.
    private func refuse(_ reason: String) {
        NSSound.beep()
        refusal = reason
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if refusal == reason { refusal = nil } }
    }

    private func stop() {
        refusal = nil
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        monitor = nil
        clickMonitor = nil
        Host.shared.registerHotkeys()
    }
}

/// "esc cancel · ⌫ remove" under the recorder: one short line, so rows grow only a little.
private struct RecorderHint: View {
    let canClear: Bool

    private func key(_ k: String) -> some View {
        Text(k)
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(.secondary.opacity(0.5), lineWidth: 0.75))
    }

    var body: some View {
        HStack(spacing: 3) {
            key("esc")
            Text("cancel")
            if canClear {
                key("⌫").padding(.leading, 5)
                Text("remove")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(height: 13)
        .fixedSize()
    }
}

// MARK: Open Slashlight

/// The welcome tour's hotkey choice, at Settings' scale: three common keys and one to record.
private struct OpenHotkeyPicker: View {
    @ObservedObject var model: SettingsModel

    static let presets: [(value: String, name: String)] = [
        ("cmd+space", "Command Space"), ("opt+space", "Option Space"), ("ctrl+space", "Control Space"),
    ]

    private var value: String { model.settings.hotkey }
    private var isCustom: Bool { !Self.presets.contains { $0.value == value } }
    private func set(_ v: String) { model.update { $0.hotkey = v } }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Self.presets, id: \.value) { p in
                ChoiceCard(selected: value == p.value, action: { set(p.value) }) {
                    HStack(spacing: 4) {
                        ForEach(HotkeyLabels.keys(p.value), id: \.self) { BigKey(label: $0, height: 24) }
                    }
                    .frame(height: 30)
                    CardCaption(name: p.name)
                }
            }
            ChoiceCard(selected: isCustom, action: nil) {
                HotkeyRecorder(value: Binding(get: { value }, set: { set($0) }), placeholder: isCustom ? nil : "Record")
                    .controlSize(.small)
                    .frame(height: 30)
                CardCaption(name: "Custom")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CardCaption: View {
    let name: String

    var body: some View {
        Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
    }
}

/// A selectable tile in the system's colours: accent border and check when chosen.
private struct ChoiceCard<Content: View>: View {
    let selected: Bool
    /// Nil when the content handles clicks itself (the recorder).
    let action: (() -> Void)?
    @ViewBuilder let content: Content
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let card = VStack(spacing: 8) { content }
            .frame(maxWidth: .infinity, minHeight: 72)
            .padding(.horizontal, 6)
            .background(shape.fill(Color.primary.opacity(hover || selected ? 0.07 : 0.04)))
            .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(5)
                    .opacity(selected ? 1 : 0)
            }
            .contentShape(shape)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.15), value: selected)
            .animation(.easeOut(duration: 0.12), value: hover)
        if let action {
            Button(action: action) { card }.buttonStyle(.plain)
        } else {
            card
        }
    }
}

// MARK: Hotkeys

private struct HotkeysSettings: View {
    @ObservedObject var model: SettingsModel

    private func groups(_ all: [HotkeyBinding]) -> [(group: HotkeyBinding.Group, rows: [HotkeyBinding])] {
        var out: [(group: HotkeyBinding.Group, rows: [HotkeyBinding])] = []
        for b in all where b.isListed && matches(b) {
            if let i = out.firstIndex(where: { $0.group == b.group }) { out[i].rows.append(b) }
            else { out.append((b.group, [b])) }
        }
        return out
    }

    private func matches(_ b: HotkeyBinding) -> Bool {
        let f = model.hotkeyFilter
        return f.isEmpty || Fuzzy.score(f, [b.title, b.ownerTitle, b.group.title, b.shortcut?.display ?? ""]) != nil
    }

    var body: some View {
        let all = model.hotkeys
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Find a hotkey", text: $model.hotkeyFilter, prompt: Text("Find a hotkey"))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                    }
                }
                ForEach(groups(all), id: \.group) { group in
                    Section(group.group.title) {
                        if group.group == .windows {
                            Toggle("Use Window Layout's global keys", isOn: model.binding(\.windowManagementHotkeys))
                        }
                        ForEach(group.rows) { b in HotkeyRow(binding: b, all: all, model: model) }
                    }
                }
                Section {
                    LabeledContent("All hotkeys") {
                        Button("Reset to Defaults", role: .destructive, action: model.resetAllHotkeys)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: 18) {
                ScopeLegend(scope: .global, text: "anywhere on your Mac")
                ScopeLegend(scope: .system, text: "anywhere in Slashlight")
                ScopeLegend(scope: .local, text: "only in that extension")
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
        }
        .id(model.extensionsVersion)
    }
}

/// The icon that says where a key works: a globe, Slashlight's own mark, or a puzzle piece.
struct ScopeIcon: View {
    let scope: HotkeyBinding.Scope
    var size: CGFloat = 13

    var body: some View {
        Group {
            switch scope {
            case .global: Image(systemName: "globe").font(.system(size: size))
            case .system: SlashlightGlyph(size: size + 1)
            case .local: Image(systemName: "puzzlepiece.extension").font(.system(size: size))
            }
        }
        .foregroundStyle(.secondary)
        .help(scope.help)
    }
}

private struct ScopeLegend: View {
    let scope: HotkeyBinding.Scope
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            ScopeIcon(scope: scope, size: 11)
            Text(text)
        }
    }
}

private struct HotkeyRow: View {
    let binding: HotkeyBinding
    let all: [HotkeyBinding]
    @ObservedObject var model: SettingsModel

    private var warning: String? {
        guard binding.isEditable else { return nil }
        if let s = binding.shortcut, let reason = ReservedKeys.reason(s, scope: binding.scope) { return reason }
        let clashes = HotkeyMap.conflicts(of: binding, in: all)
        if !clashes.isEmpty {
            return "Also used by " + clashes.map(\.title).joined(separator: ", ")
        }
        if model.host.failedHotkeys.contains(binding.id) { return "macOS or another app already uses this key" }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ScopeIcon(scope: binding.scope).frame(width: 18, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(binding.title).lineLimit(1).frame(height: 22)
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button { model.resetHotkey(binding) } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless)
                .help("Back to \(binding.defaultShortcut?.display ?? "no key")")
                .frame(height: 22)
                .opacity(binding.isDefault ? 0 : 1)
                .disabled(binding.isDefault)
            HotkeyRecorder(value: Binding(get: { binding.shortcut?.string ?? "" },
                                          set: { model.setHotkey(binding, $0) }),
                           scope: binding.scope, canClear: true, showsHint: true)
        }
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
/// The real panel, drawn with its own parts at a smaller scale over a busy wallpaper, so the opacity and blur
/// settings show what they will do.
private struct PanelPreview: View {
    @ObservedObject var style = PanelStyle.shared
    private let scale: CGFloat = 0.62

    private static let rows: [PaletteModel.Row] = [
        ("safari", "Safari", Icon.file("/Applications/Safari.app")),
        ("notes", "Notes", Icon.file("/System/Applications/Notes.app")),
        ("clipboard", "Clipboard History", Icon.symbol("doc.on.clipboard")),
    ].enumerated().map { i, r in
        PaletteModel.Row(id: r.0, index: i, item: Item(id: r.0, title: r.1, icon: r.2, primary: Action("Open") { .close }), extensionID: nil)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .light)).foregroundStyle(Theme.text)
                Text("Search…").font(.system(size: 20)).foregroundStyle(Theme.secondary)
                Spacer()
                Keycap(label: "esc")
            }
            .padding(.horizontal, 18)
            .frame(height: 60)
            Rectangle().fill(Theme.divider).frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                Text("RECENT")
                    .font(.system(size: 11, weight: .medium)).tracking(1.4).foregroundStyle(Theme.secondary)
                    .padding(.leading, 10).padding(.top, 8).padding(.bottom, 4)
                ForEach(Self.rows) { row in ResultRow(row: row, selected: row.index == 0, plain: true) }
            }
            .padding(8)
            HStack(spacing: 14) {
                ForEach([("↵", "Open"), ("⌘K", "Actions"), ("↑↓", "Navigate")], id: \.0) { k, label in
                    HStack(spacing: 6) {
                        Keycap(label: k)
                        Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(Theme.footer.opacity(style.opacity))
            .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
        }
        .frame(width: Theme.width)
        .background(PanelBackground(style: style, blending: .withinWindow))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.orange, .pink, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Something with edges behind the panel, so blur and see-through are visible.
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<6) { i in
                    RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.75)).frame(width: CGFloat(140 + (i * 53) % 220), height: 9)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 40)
            panel
                .scaleEffect(scale)
                .frame(width: Theme.width * scale, height: 286 * scale)
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
