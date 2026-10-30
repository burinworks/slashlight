import AppKit
import SlashlightKit
import SwiftUI

/// The icon's indigo-to-black palette (scripts/icon/icon.swift), plus surfaces that read on both backgrounds.
enum Brand {
    static let indigo = Color(red: 0.20, green: 0.17, blue: 0.42)
    static let ink = Color(red: 0.05, green: 0.05, blue: 0.10)
    static let glow = Color(red: 0.55, green: 0.62, blue: 1)
    static let accent = dynamic(NSColor(hex: 0x4B45C6), NSColor(hex: 0x8F9CFF))
    static let accentText = dynamic(.white, NSColor(hex: 0x0D0D1A))
    static let card = dynamic(NSColor(white: 1, alpha: 0.72), NSColor(white: 1, alpha: 0.06))
    static let cardStroke = dynamic(NSColor(white: 0, alpha: 0.08), NSColor(white: 1, alpha: 0.10))
    static let secondary = dynamic(NSColor(hex: 0x5E5C72), NSColor(hex: 0xA6A8C4))

    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

private struct StillKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True while rendering a snapshot: every animation shows its resting frame.
    var onboardingStill: Bool {
        get { self[StillKey.self] }
        set { self[StillKey.self] = newValue }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            OnboardingBackground()
            VStack(spacing: 0) {
                ZStack {
                    step(model.step)
                        .id(model.step)
                        .transition(transition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 34)
                footer
            }
        }
        .frame(width: OnboardingWindowController.size.width, height: OnboardingWindowController.size.height)
        .ignoresSafeArea()
        .environment(\.onboardingStill, model.still)
    }

    @ViewBuilder private func step(_ s: OnboardingStep) -> some View {
        switch s {
        case .welcome: WelcomeStep()
        case .hotkey: HotkeyStep(model: model)
        case .search: SearchStep()
        case .extensions: ExtensionsStep()
        case .permissions: PermissionsStep(model: model)
        case .done: DoneStep(model: model)
        }
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        let d: CGFloat = model.forward ? 1 : -1
        return .asymmetric(insertion: .modifier(active: StepSlide(x: 70 * d), identity: StepSlide(x: 0, shown: true)),
                           removal: .modifier(active: StepSlide(x: -70 * d), identity: StepSlide(x: 0, shown: true)))
    }

    private var footer: some View {
        HStack {
            Button(action: model.back) {
                Label("Back", systemImage: "chevron.left").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(GhostButtonStyle())
            .keyboardShortcut(.leftArrow, modifiers: [])
            .opacity(model.step == .welcome ? 0 : 1)
            .disabled(model.step == .welcome)
            .frame(width: 170, alignment: .leading)

            Spacer()
            ProgressDots(current: model.step, onSelect: model.go(to:))
            Spacer()

            Button(action: model.next) {
                HStack(spacing: 6) {
                    Text(nextTitle)
                    Image(systemName: model.step == .done ? "arrow.up.forward" : "arrow.right")
                }
                .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .frame(width: 170, alignment: .trailing)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var nextTitle: String {
        switch model.step {
        case .welcome: return "Get Started"
        case .done: return "Open Slashlight"
        default: return "Continue"
        }
    }
}

private struct StepSlide: ViewModifier {
    let x: CGFloat
    var shown = false

    func body(content: Content) -> some View {
        content
            .offset(x: x)
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 6)
            .scaleEffect(shown ? 1 : 0.97)
    }
}

// MARK: Background

/// Slow-drifting light blobs and faint particles over the brand gradient. Frozen under Reduce Motion.
struct OnboardingBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingStill) private var still

    var body: some View {
        let frozen = reduceMotion || still
        TimelineView(.animation(minimumInterval: 1 / 30, paused: frozen)) { context in
            let t = frozen ? 14 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)
            Canvas { gc, size in draw(&gc, size: size, t: t) }
        }
        .ignoresSafeArea()
    }

    private func draw(_ gc: inout GraphicsContext, size: CGSize, t: Double) {
        let dark = scheme == .dark
        let rect = CGRect(origin: .zero, size: size)
        let base = dark ? [Brand.indigo, Brand.ink, Color(red: 0.03, green: 0.03, blue: 0.06)]
                        : [Color(red: 0.97, green: 0.96, blue: 1), Color(red: 0.93, green: 0.92, blue: 0.99)]
        gc.fill(Path(rect), with: .linearGradient(Gradient(colors: base), startPoint: .zero, endPoint: CGPoint(x: size.width * 0.3, y: size.height)))

        // (phase, speed, radius, color) for each blob; they wander on slow Lissajous paths.
        let blobs: [(Double, Double, CGFloat, Color)] = [
            (0, 0.050, 0.55, Brand.glow.opacity(dark ? 0.30 : 0.32)),
            (2.1, 0.037, 0.45, Color(red: 0.45, green: 0.32, blue: 0.95).opacity(dark ? 0.32 : 0.20)),
            (4.2, 0.043, 0.38, Color(red: 0.30, green: 0.55, blue: 1).opacity(dark ? 0.18 : 0.16)),
        ]
        for (phase, speed, r, color) in blobs {
            let c = CGPoint(x: size.width * (0.5 + 0.38 * sin(t * speed + phase)),
                            y: size.height * (0.42 + 0.32 * cos(t * speed * 1.3 + phase * 1.7)))
            let radius = size.width * r
            gc.fill(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                    with: .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: c, startRadius: 0, endRadius: radius))
        }

        // Particles rise slowly and twinkle; positions come from a fixed hash so they are stable between frames.
        for i in 0..<46 {
            let h1 = hash(i, 1), h2 = hash(i, 2), h3 = hash(i, 3)
            let y = (h2 * size.height - t * (6 + h3 * 10)).truncatingRemainder(dividingBy: size.height)
            let p = CGPoint(x: h1 * size.width + sin(t * 0.3 + h3 * 6) * 8, y: y < 0 ? y + size.height : y)
            let twinkle = 0.5 + 0.5 * sin(t * (0.8 + h1) + h2 * 10)
            let d = 1 + h3 * 2
            let color: Color = dark ? .white : Brand.indigo
            gc.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: d, height: d)),
                    with: .color(color.opacity((dark ? 0.12 : 0.10) + twinkle * (dark ? 0.35 : 0.18))))
        }
    }

    private func hash(_ i: Int, _ salt: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + Double(salt) * 78.233) * 43758.5453
        return x - x.rounded(.down)
    }
}

// MARK: Shared pieces

struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .tracking(-0.4)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(Brand.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .appear(0.05)
    }
}

/// Fades and lifts a view in after `delay` when its step appears.
private struct Appear: ViewModifier {
    let delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingStill) private var still

    func body(content: Content) -> some View {
        content
            .opacity(shown || still ? 1 : 0)
            .offset(y: shown || still || reduceMotion ? 0 : 16)
            .onAppear {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(reduceMotion ? 0 : delay)) { shown = true }
            }
    }
}

extension View {
    func appear(_ delay: Double) -> some View { modifier(Appear(delay: delay)) }

    /// A translucent rounded card.
    func card(radius: CGFloat = 16) -> some View {
        background(Brand.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Brand.cardStroke, lineWidth: 1))
    }

    /// The same surface as a capsule, for chips.
    func capsuleCard() -> some View {
        background(Brand.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Brand.cardStroke, lineWidth: 1))
    }
}

/// The app icon drawn natively so it can animate: the slash strokes in and its glow breathes.
struct AppIconMark: View {
    var size: CGFloat
    var slash: CGFloat = 1
    var glow: Double = 1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2245, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Brand.indigo, Brand.ink], startPoint: .top, endPoint: .bottom))
            shape.fill(RadialGradient(colors: [Brand.glow.opacity(0.55 * (0.7 + 0.3 * glow)), Brand.glow.opacity(0)],
                                      center: UnitPoint(x: 0.5, y: 0.44), startRadius: 0, endRadius: size * 0.51))
            SlashShape()
                .trim(from: 0, to: slash)
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.126, lineCap: .round))
                .shadow(color: Brand.glow.opacity(0.9 * glow), radius: size * 0.06)
                .shadow(color: Brand.glow.opacity(0.5 * glow), radius: size * 0.12)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: size * 0.05, y: size * 0.03)
    }
}

private struct SlashShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.364, y: r.minY + r.height * 0.806))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.636, y: r.minY + r.height * 0.194))
        return p
    }
}

/// A chunky keyboard key. `pressed` sinks it.
struct BigKey: View {
    let label: String
    var height: CGFloat = 44
    var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height * 0.22, style: .continuous)
        Text(label)
            .font(.system(size: height * (label.count > 1 ? 0.33 : 0.45), weight: .medium, design: .rounded))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, label.count > 1 ? height * 0.4 : 0)
            .frame(minWidth: height, minHeight: height)
            .background(shape.fill(Theme.keycapFill))
            .overlay(shape.stroke(Theme.keycapBorder, lineWidth: 1))
            .background(shape.fill(Theme.keycapBorder).offset(y: pressed ? 1 : height * 0.08))
            .offset(y: pressed ? height * 0.06 : 0)
    }
}

enum HotkeyLabels {
    /// "opt+space" → ["⌥", "Space"]
    static func keys(_ value: String) -> [String] {
        guard let s = Shortcut(string: value) else { return [value] }
        var keys: [String] = []
        if s.modifiers.contains(.control) { keys.append("⌃") }
        if s.modifiers.contains(.option) { keys.append("⌥") }
        if s.modifiers.contains(.shift) { keys.append("⇧") }
        if s.modifiers.contains(.command) { keys.append("⌘") }
        keys.append(Shortcut(s.key).display)
        return keys
    }
}

private struct ProgressDots: View {
    let current: OnboardingStep
    let onSelect: (OnboardingStep) -> Void

    var body: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStep.allCases, id: \.self) { s in
                Capsule()
                    .fill(s == current ? Brand.accent : Color.primary.opacity(s.rawValue < current.rawValue ? 0.35 : 0.15))
                    .frame(width: s == current ? 22 : 7, height: 7)
                    .contentShape(Rectangle().inset(by: -4))
                    .onTapGesture { onSelect(s) }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Brand.accentText)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(Brand.accent))
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: Brand.accent.opacity(0.45), radius: configuration.isPressed ? 4 : 10, y: 3)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Brand.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.0001)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Smaller bordered capsule for in-step actions ("Grant Access", "Open Keyboard Shortcuts").
struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Brand.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Brand.accent.opacity(configuration.isPressed ? 0.22 : 0.12)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
