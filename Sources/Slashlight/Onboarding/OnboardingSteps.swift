import AppKit
import SlashlightKit
import SwiftUI

// MARK: 1. Welcome

struct WelcomeStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingStill) private var still
    @State private var shown = false
    @State private var slash: CGFloat = 0

    var body: some View {
        let calm = reduceMotion || still
        VStack(spacing: 26) {
            Spacer(minLength: 0)
            TimelineView(.animation(paused: calm)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                AppIconMark(size: 150, slash: calm ? 1 : slash, glow: calm ? 1 : 0.75 + 0.25 * sin(t * 1.6))
                    .offset(y: calm ? 0 : sin(t * 1.1) * 4)
                    .rotation3DEffect(.degrees(calm ? 0 : sin(t * 0.7) * 6), axis: (x: 0.3, y: 1, z: 0))
            }
            .scaleEffect(shown || calm ? 1 : 0.6)
            .opacity(shown || calm ? 1 : 0)
            StepHeader(title: "Welcome to Slashlight",
                       subtitle: "A keyboard-first launcher for apps, files, math, commands and terminals. Setup takes about a minute.")
            HStack(spacing: 10) {
                FeatureChip(symbol: "keyboard", text: "Keyboard-first")
                FeatureChip(symbol: "bolt", text: "Native and fast")
                FeatureChip(symbol: "puzzlepiece.extension", text: "Extensible")
                FeatureChip(symbol: "chevron.left.forwardslash.chevron.right", text: "Open source")
            }
            .appear(0.35)
            Spacer(minLength: 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.6)) { shown = true }
            withAnimation(.easeOut(duration: 0.7).delay(0.25)) { slash = 1 }
        }
    }
}

private struct FeatureChip: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Brand.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .fixedSize()
            .capsuleCard()
    }
}

// MARK: 2. Hotkey

struct HotkeyStep: View {
    @ObservedObject var model: OnboardingModel

    private static let presets: [(value: String, name: String, note: String)] = [
        ("cmd+space", "Command Space", "Replaces Spotlight"),
        ("opt+space", "Option Space", "The default"),
        ("ctrl+space", "Control Space", "Rarely taken"),
    ]

    private var isCustom: Bool { !Self.presets.contains { $0.value == model.hotkey } }

    var body: some View {
        VStack(spacing: 26) {
            StepHeader(title: "Pick your hotkey",
                       subtitle: "It opens Slashlight from any app. You can change it any time in Settings.")
            HStack(spacing: 12) {
                ForEach(Array(Self.presets.enumerated()), id: \.offset) { i, p in
                    HotkeyCard(selected: model.hotkey == p.value, keys: HotkeyLabels.keys(p.value), name: p.name, note: p.note) {
                        model.setHotkey(p.value)
                    }
                    .appear(0.12 + Double(i) * 0.06)
                }
                CustomHotkeyCard(selected: isCustom, value: Binding(get: { model.hotkey }, set: { model.setHotkey($0) }))
                    .appear(0.30)
            }
            ZStack {
                if model.hotkey == "cmd+space" {
                    SpotlightCallout(owned: model.spotlightOwnsCommandSpace)
                        .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(height: 74, alignment: .top)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: model.hotkey)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: model.spotlightOwnsCommandSpace)
        }
        .padding(.top, 18)
    }
}

private struct HotkeyCard: View {
    let selected: Bool
    let keys: [String]
    let name: String
    let note: String
    let action: () -> Void
    @State private var pressed = false
    @State private var hover = false

    var body: some View {
        Button {
            action()
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { pressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { pressed = false }
            }
        } label: {
            CardBody(selected: selected, hover: hover) {
                HStack(spacing: 5) {
                    ForEach(keys, id: \.self) { BigKey(label: $0, height: 36, pressed: pressed) }
                }
                .frame(height: 46)
                VStack(spacing: 2) {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    Text(note).font(.system(size: 11)).foregroundStyle(Brand.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hover = h } }
    }
}

private struct CustomHotkeyCard: View {
    let selected: Bool
    @Binding var value: String

    var body: some View {
        CardBody(selected: selected, hover: false) {
            HotkeyRecorder(value: $value, placeholder: selected ? nil : "Record")
                .frame(height: 46)
            VStack(spacing: 2) {
                Text("Custom").font(.system(size: 13, weight: .semibold))
                Text(selected ? "Click to change" : "Click, then press keys").font(.system(size: 11)).foregroundStyle(Brand.secondary)
            }
        }
    }
}

/// Shared frame for the four hotkey choices: lifts on hover, glows when selected.
private struct CardBody<Content: View>: View {
    let selected: Bool
    let hover: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 14) { content }
            .frame(width: 150, height: 132)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.card)
                .shadow(color: Brand.accent.opacity(selected ? 0.35 : 0), radius: 14, y: 4))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.cardStroke, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.accent, lineWidth: selected ? 2 : 0))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Brand.accentText, Brand.accent)
                    .padding(8)
                    .scaleEffect(selected ? 1 : 0.3)
                    .opacity(selected ? 1 : 0)
            }
            .scaleEffect(selected ? 1.03 : hover ? 1.015 : 1)
            .offset(y: hover && !selected ? -2 : 0)
            .animation(.spring(response: 0.4, dampingFraction: 0.65), value: selected)
    }
}

private struct SpotlightCallout: View {
    let owned: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: owned ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .font(.system(size: 20))
                .foregroundStyle(owned ? .orange : .green)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(owned ? "macOS Spotlight already uses ⌘Space" : "Spotlight's shortcut is off. ⌘Space is yours.")
                    .font(.system(size: 13, weight: .semibold))
                Text(owned ? "Turn it off in System Settings → Keyboard → Keyboard Shortcuts → Spotlight, then come back."
                           : "Slashlight picked it up; no restart needed.")
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if owned {
                Button("Open Keyboard Shortcuts", action: SpotlightShortcut.openKeyboardShortcuts)
                    .buttonStyle(SoftButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 636)
        .card(radius: 14)
    }
}

// MARK: 3. Search

struct SearchStep: View {
    var body: some View {
        VStack(spacing: 24) {
            StepHeader(title: "Just start typing", subtitle: "Apps, math, commands and your shell all live in one bar.")
            SearchDemo().appear(0.15)
        }
        .padding(.top, 14)
    }
}

/// A miniature panel that types example queries on a loop. Click a chip to jump to one.
private struct SearchDemo: View {
    struct Scenario {
        let query: String
        let label: String
        let symbol: String
    }

    static let scenarios = [
        Scenario(query: "saf", label: "Apps", symbol: "app.dashed"),
        Scenario(query: "5 km in mi", label: "Calculator", symbol: "function"),
        Scenario(query: "/", label: "Commands", symbol: "slash.circle"),
        Scenario(query: "> npm run dev", label: "Terminal", symbol: "terminal"),
    ]

    @Environment(\.onboardingStill) private var still
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var start = 0
    @State private var typed = ""
    @State private var showResults = false
    @State private var run = 0

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(Theme.secondary)
                    HStack(spacing: 1) {
                        Text(typed.isEmpty ? " " : typed).font(.system(size: 19)).foregroundStyle(Theme.text)
                        Caret()
                    }
                    Spacer()
                    Keycap(label: "esc")
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                Rectangle().fill(Theme.divider).frame(height: 1)
                ZStack(alignment: .top) {
                    if showResults {
                        results(index)
                            .frame(maxWidth: .infinity, alignment: .top)
                            .id(index)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 214, maxHeight: 214, alignment: .top) // fixed, or it collapses while empty
                .clipped()
            }
            .frame(width: 540)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.panel)
                .shadow(color: .black.opacity(0.25), radius: 24, y: 10))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.border, lineWidth: 0.5))

            HStack(spacing: 8) {
                ForEach(Array(Self.scenarios.enumerated()), id: \.offset) { i, s in
                    Button { start = i; run += 1 } label: {
                        Label(s.label, systemImage: s.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(i == index ? Brand.accentText : Brand.secondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(i == index ? Brand.accent : Brand.card))
                            .overlay(Capsule().strokeBorder(Brand.cardStroke, lineWidth: i == index ? 0 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: index)
        }
        .task(id: run) { await play(from: start) }
    }

    private func play(from first: Int) async {
        if still {
            index = 2
            typed = Self.scenarios[2].query
            showResults = true
            return
        }
        var i = first
        while !Task.isCancelled {
            // Clear the old answer before switching, so the next one never flashes in early.
            withAnimation(.easeOut(duration: 0.15)) { showResults = false }
            try? await Task.sleep(nanoseconds: 200_000_000)
            index = i
            typed = ""
            try? await Task.sleep(nanoseconds: 300_000_000)
            for ch in Self.scenarios[i].query {
                guard !Task.isCancelled else { return }
                typed.append(ch)
                try? await Task.sleep(nanoseconds: UInt64.random(in: 55_000_000...120_000_000))
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { showResults = true }
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            i = (i + 1) % Self.scenarios.count
        }
    }

    @ViewBuilder private func results(_ i: Int) -> some View {
        switch i {
        case 0:
            VStack(spacing: 2) {
                section("Applications")
                DemoRow(icon: appIcon("Safari"), title: "Safari", subtitle: "/Applications", selected: true, accessory: "Open")
                DemoRow(icon: .symbol("safari"), title: "Safari Settings…", subtitle: "Command")
                DemoRow(icon: .symbol("magnifyingglass"), title: "Search the web for “saf”", subtitle: "Google")
            }
        case 1:
            VStack(spacing: 12) {
                section("Calculator")
                HStack(spacing: 0) {
                    calcSide("5 km", "Kilometres")
                    Image(systemName: "arrow.right").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.secondary)
                    calcSide("3.107 mi", "Miles")
                }
                .frame(height: 110)
                .background(Theme.selection, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 10)
                HStack { Spacer(); Keycap(label: "↵"); Text("Copy").font(.system(size: 11)).foregroundStyle(Theme.secondary) }
                    .padding(.horizontal, 14)
            }
        case 2:
            VStack(spacing: 2) {
                section("Extensions")
                DemoRow(icon: .symbol("doc.on.clipboard"), title: "Clipboard History", subtitle: "/clipboard", selected: true, accessory: "Open")
                DemoRow(icon: .symbol("text.quote"), title: "Snippets", subtitle: "/snippets")
                DemoRow(icon: .symbol("face.smiling"), title: "Emoji & Symbols", subtitle: "/emoji")
                DemoRow(icon: .symbol("rectangle.split.2x1"), title: "Left Half", subtitle: "/left-half")
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                section("Terminal")
                DemoRow(icon: .symbol("terminal"), title: "Run in a terminal tab", subtitle: "npm run dev", selected: true, accessory: "Run")
                VStack(alignment: .leading, spacing: 3) {
                    Text("~/app $ npm run dev").foregroundStyle(.white.opacity(0.9))
                    Text("  VITE v6.0.0  ready in 312 ms").foregroundStyle(Color(red: 0.5, green: 0.9, blue: 0.6))
                    Text("  ➜  Local:   http://localhost:5173/").foregroundStyle(.white.opacity(0.65))
                }
                .font(.system(size: 11.5, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(red: 0.08, green: 0.08, blue: 0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 10)
            }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private func calcSide(_ value: String, _ unit: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.text)
            Text(unit).font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func appIcon(_ name: String) -> Icon {
        for dir in ["/Applications", "/System/Applications", "/System/Cryptexes/App/System/Applications"] {
            let path = "\(dir)/\(name).app"
            if FileManager.default.fileExists(atPath: path) { return .file(path) }
        }
        return .symbol("safari")
    }
}

private struct DemoRow: View {
    let icon: Icon
    let title: String
    let subtitle: String
    var selected = false
    var accessory: String?

    var body: some View {
        HStack(spacing: 10) {
            IconView(icon: icon, size: 26)
            Text(title).font(.system(size: 13.5)).foregroundStyle(Theme.text)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Spacer()
            if let accessory, selected {
                Text(accessory).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Keycap(label: "↵")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 8)
    }
}

private struct Caret: View {
    @Environment(\.onboardingStill) private var still
    @State private var on = true

    var body: some View {
        Rectangle()
            .fill(Brand.accent)
            .frame(width: 2, height: 22)
            .opacity(on || still ? 1 : 0)
            .onAppear {
                guard !still else { return }
                withAnimation(.easeInOut(duration: 0.5).repeatForever()) { on = false }
            }
    }
}

// MARK: 4. Extensions

struct ExtensionsStep: View {
    var body: some View {
        VStack(spacing: 26) {
            StepHeader(title: "Everything is an extension",
                       subtitle: "Built-ins and your own work the same way. Three places to find them:")
            HStack(spacing: 14) {
                PlaceCard(number: 1, title: "Empty bar", caption: "Recently used extensions first, then all of them A–Z.") {
                    MiniBar(text: "") {
                        MiniRow(symbol: "doc.on.clipboard", title: "Clipboard History")
                        MiniRow(symbol: "terminal", title: "Terminal")
                        MiniRow(symbol: "face.smiling", title: "Emoji & Symbols")
                    }
                }
                .appear(0.12)
                PlaceCard(number: 2, title: "Type /", caption: "Command mode: every extension and your own commands.") {
                    MiniBar(text: "/") {
                        MiniRow(symbol: "text.quote", title: "/snippets")
                        MiniRow(symbol: "macwindow.on.rectangle", title: "/switch")
                        MiniRow(symbol: "power", title: "/system")
                    }
                }
                .appear(0.2)
                PlaceCard(number: 3, title: "Settings → Extensions", caption: "Turn extensions on or off and open the folder for your own.") {
                    VStack(spacing: 0) {
                        MiniToggleRow(symbol: "app.dashed", title: "All Apps", on: true)
                        MiniToggleRow(symbol: "folder", title: "Files", on: true)
                        MiniToggleRow(symbol: "globe", title: "Search the Web", on: false)
                    }
                    .padding(6)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
                }
                .appear(0.28)
            }
            Button("Open Settings → Extensions") { SettingsWindowController.shared.show(tab: .extensions) }
                .buttonStyle(SoftButtonStyle())
                .appear(0.36)
        }
        .padding(.top, 14)
    }
}

private struct PlaceCard<Preview: View>: View {
    let number: Int
    let title: String
    let caption: String
    @ViewBuilder let preview: Preview
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            preview.frame(height: 138, alignment: .top)
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.accentText)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Brand.accent))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            Text(caption)
                .font(.system(size: 11.5))
                .foregroundStyle(Brand.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 214, height: 256)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Brand.card)
            .shadow(color: .black.opacity(hover ? 0.12 : 0), radius: 14, y: 6))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Brand.cardStroke, lineWidth: 1))
        .scaleEffect(hover ? 1.02 : 1)
        .offset(y: hover ? -3 : 0)
        .onHover { h in withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { hover = h } }
    }
}

private struct MiniBar<Rows: View>: View {
    let text: String
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                Text(text.isEmpty ? "Search…" : text)
                    .font(.system(size: 12))
                    .foregroundStyle(text.isEmpty ? Theme.secondary : Theme.text)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            Rectangle().fill(Theme.divider).frame(height: 1)
            VStack(spacing: 1) { rows }.padding(5)
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
    }
}

private struct MiniRow: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 7) {
            IconView(icon: .symbol(symbol), size: 18)
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 5)
        .frame(height: 28)
    }
}

private struct MiniToggleRow: View {
    let symbol: String
    let title: String
    let on: Bool

    var body: some View {
        HStack(spacing: 7) {
            IconView(icon: .symbol(symbol), size: 18)
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer()
            Capsule()
                .fill(on ? Brand.accent : Theme.tile)
                .frame(width: 24, height: 14)
                .overlay(alignment: on ? .trailing : .leading) { Circle().fill(.white).padding(2).shadow(radius: 0.5) }
        }
        .padding(.horizontal, 5)
        .frame(height: 38)
    }
}

// MARK: 5. Permissions

struct PermissionsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 26) {
            StepHeader(title: "Two optional permissions",
                       subtitle: "Slashlight works without them. Each one unlocks a few extras, and you can grant them later in Settings → Permissions.")
            VStack(spacing: 12) {
                PermissionCard(permission: .accessibility, symbol: "accessibility", tint: .blue,
                               detail: "Paste into the app you came from and move windows with ⌃⌥ + arrows.",
                               granted: model.permissions[.accessibility] ?? false)
                    .appear(0.14)
                PermissionCard(permission: .screenRecording, symbol: "rectangle.dashed.badge.record", tint: .purple,
                               detail: "Show window titles in the window switcher (⌥Tab). Slashlight never records your screen.",
                               granted: model.permissions[.screenRecording] ?? false)
                    .appear(0.22)
            }
            Label("Both are optional. Skip this step if you like.", systemImage: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Brand.secondary)
                .appear(0.3)
        }
        .padding(.top, 14)
    }
}

private struct PermissionCard: View {
    let permission: Permission
    let symbol: String
    let tint: Color
    let detail: String
    let granted: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(Permissions.title(permission)).font(.system(size: 14, weight: .semibold))
                    Text("Optional")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            ZStack {
                if granted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    Button("Grant Access") { Permissions.request(permission) }
                        .buttonStyle(SoftButtonStyle())
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .frame(width: 112, alignment: .trailing)
        }
        .padding(16)
        .frame(width: 600)
        .card(radius: 16)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.green.opacity(granted ? 0.45 : 0), lineWidth: 1.5))
    }
}

// MARK: 6. Statistics

/// Consent for anonymous statistics. Both answers look the same and neither is chosen up front:
/// consent has to be an active, free choice. Skipping leaves the setting nil, which sends nothing.
struct StatisticsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 26) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(LinearGradient(colors: [Brand.glow, Brand.indigo], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Brand.glow.opacity(0.4), radius: 14, y: 4)
                .appear(0)
            StepHeader(title: "Help improve Slashlight",
                       subtitle: "Share anonymous usage statistics: which extensions are used, app and macOS versions. No search text, no file names, no clipboard. Everything collected is published on a public dashboard anyone can see.")
            HStack(spacing: 12) {
                ConsentButton(title: "Share statistics", symbol: "checkmark.circle", chosen: model.shareStatistics == true) {
                    model.setShareStatistics(true)
                }
                ConsentButton(title: "Don't share", symbol: "xmark.circle", chosen: model.shareStatistics == false) {
                    model.setShareStatistics(false)
                }
            }
            .appear(0.15)
            Text("You can change this any time in Settings → General.")
                .font(.system(size: 12))
                .foregroundStyle(Brand.secondary)
                .appear(0.22)
        }
        .padding(.top, 6)
    }
}

/// One of the two consent answers. Both use this same style; the chosen one gets an outline.
private struct ConsentButton: View {
    let title: String
    let symbol: String
    let chosen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: chosen ? symbol + ".fill" : symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(chosen ? Brand.accent : Color.primary)
                .frame(width: 200, height: 44)
                .card(radius: 12)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.accent, lineWidth: chosen ? 2 : 0))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: chosen)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

// MARK: 7. Done

struct DoneStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingStill) private var still
    @State private var pressed = -1
    @State private var burst = false

    var body: some View {
        let keys = HotkeyLabels.keys(model.hotkey)
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            ZStack {
                if !reduceMotion && !still { Burst(fired: burst) }
                HStack(spacing: 10) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { i, k in
                        BigKey(label: k, height: 72, pressed: pressed >= i)
                    }
                }
                .shadow(color: Brand.glow.opacity(0.35), radius: 30)
            }
            .frame(height: 120)
            .appear(0.05)
            VStack(spacing: 10) {
                Text("You're all set")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .tracking(-0.4)
                (Text("Press ") + Text(model.hotkeyDisplay).foregroundColor(Brand.accent).bold() + Text(" from any app to start."))
                    .font(.system(size: 15))
                    .foregroundStyle(Brand.secondary)
            }
            .appear(0.12)
            HStack(spacing: 10) {
                Tip(keys: "⌘K", text: "Every action")
                Tip(keys: "⌘,", text: "Settings")
                Tip(keys: "⌥Tab", text: "Switch windows")
                Tip(keys: "esc", text: "Close")
            }
            .appear(0.22)
            Spacer(minLength: 0)
        }
        .task {
            guard !reduceMotion, !still else { return }
            try? await Task.sleep(nanoseconds: 450_000_000)
            burst = true
            // Play the hotkey on the keycaps, then again every few seconds.
            while !Task.isCancelled {
                for i in keys.indices {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.55)) { pressed = i }
                    try? await Task.sleep(nanoseconds: 140_000_000)
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { pressed = -1 }
                try? await Task.sleep(nanoseconds: 2_800_000_000)
            }
        }
    }
}

private struct Tip: View {
    let keys: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Keycap(label: keys)
            Text(text).font(.system(size: 12)).foregroundStyle(Brand.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .fixedSize()
        .capsuleCard()
    }
}

/// A one-off ring of sparks behind the keycaps.
private struct Burst: View {
    let fired: Bool

    var body: some View {
        ZStack {
            ForEach(0..<18, id: \.self) { i in
                let angle = Double(i) / 18 * 2 * .pi
                let distance: CGFloat = fired ? CGFloat(150 + (i % 3) * 30) : 20
                Circle()
                    .fill(i % 2 == 0 ? Brand.glow : Brand.accent)
                    .frame(width: i % 3 == 0 ? 6 : 4)
                    .offset(x: cos(angle) * distance, y: sin(angle) * distance * 0.55)
                    .opacity(fired ? 0 : 1)
                    .animation(.easeOut(duration: 1.3).delay(Double(i % 4) * 0.03), value: fired)
            }
        }
        .allowsHitTesting(false)
    }
}
