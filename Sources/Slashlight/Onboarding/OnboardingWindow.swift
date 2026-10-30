import AppKit
import SlashlightKit
import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, hotkey, search, extensions, permissions, statistics, done
}

/// The welcome tour: opens by itself on first launch, and again from the menu bar icon or Settings → About.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    static let size = NSSize(width: 760, height: 560)

    private var window: NSWindow?
    private var model: OnboardingModel?

    /// `still` freezes every animation at its resting frame and saves nothing; used by `--snapshot-onboarding`.
    func show(step: OnboardingStep = .welcome, still: Bool = false) {
        if let model {
            model.go(to: step)
        } else {
            let model = OnboardingModel(step: step, still: still)
            model.onFinish = { [weak self] openPanel in self?.finish(openPanel: openPanel) }
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Welcome to Slashlight"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.delegate = self
            let hosting = NSHostingView(rootView: OnboardingView(model: model))
            hosting.sizingOptions = []
            w.contentView = hosting
            w.setFrame(NSRect(origin: .zero, size: Self.size), display: false) // the content runs under the title bar
            w.center()
            window = w
            self.model = model
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func snapshot(to path: String) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func finish(openPanel: Bool) {
        window?.close()
        if openPanel { Host.shared.show() }
    }

    func windowWillClose(_ notification: Notification) {
        // Closing early counts as done too: the tour never comes back by itself.
        if model?.still == false, !Host.shared.settings.onboardingCompleted {
            Host.shared.update { $0.onboardingCompleted = true }
        }
        window = nil
        model = nil
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published private(set) var step: OnboardingStep
    /// Direction of the last step change, for the slide transition.
    @Published private(set) var forward = true
    @Published private(set) var hotkey: String
    @Published private(set) var permissions: [Permission: Bool] = [:]
    @Published private(set) var spotlightOwnsCommandSpace = false
    /// nil until the user picks one on the statistics step.
    @Published private(set) var shareStatistics: Bool?
    let still: Bool
    var onFinish: ((_ openPanel: Bool) -> Void)?
    private var timer: Timer?

    init(step: OnboardingStep, still: Bool) {
        self.step = step
        self.still = still
        hotkey = Host.shared.settings.hotkey
        shareStatistics = Host.shared.settings.shareStatistics
        refresh()
        // Permissions and the Spotlight shortcut change in System Settings; poll so the tour reflects them live.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    var hotkeyDisplay: String { Shortcut(string: hotkey)?.display ?? hotkey }

    func next() {
        if let n = OnboardingStep(rawValue: step.rawValue + 1) { go(to: n) } else { onFinish?(true) }
    }

    func back() {
        if let p = OnboardingStep(rawValue: step.rawValue - 1) { go(to: p) }
    }

    func go(to target: OnboardingStep) {
        guard target != step else { return }
        // Set the direction first so the outgoing step already carries the matching transition.
        forward = target.rawValue > step.rawValue
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { self.step = target }
        }
    }

    func setHotkey(_ value: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { hotkey = value }
        if !still { Host.shared.update { $0.hotkey = value } }
    }

    func setShareStatistics(_ value: Bool) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { shareStatistics = value }
        if !still { Host.shared.update { $0.shareStatistics = value } }
    }

    func refresh() {
        var p: [Permission: Bool] = [:]
        for perm in [Permission.accessibility, .screenRecording] { p[perm] = Permissions.isGranted(perm) }
        if p != permissions { withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { permissions = p } }
        let owned = SpotlightShortcut.ownsCommandSpace
        if owned != spotlightOwnsCommandSpace {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { spotlightOwnsCommandSpace = owned }
            // Spotlight let go of ⌘Space: claim it now instead of on the next launch.
            if !owned, !still, hotkey == "cmd+space" { Host.shared.registerHotkeys() }
        }
    }
}

/// macOS keeps its own shortcuts in `com.apple.symbolichotkeys`; 64 is "Show Spotlight search".
enum SpotlightShortcut {
    static var ownsCommandSpace: Bool {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any],
              let entry = all["64"] as? [String: Any] else { return true } // never touched: the macOS default, on
        guard (entry["enabled"] as? Bool) ?? true else { return false }
        // parameters = [character, key code, modifier mask]; 49 is Space, 1 << 20 is ⌘.
        guard let params = (entry["value"] as? [String: Any])?["parameters"] as? [Int], params.count == 3 else { return true }
        return params[1] == 49 && params[2] == 1 << 20
    }

    static func openKeyboardShortcuts() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")!)
    }
}
