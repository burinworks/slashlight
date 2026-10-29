import AppKit
import SwiftUI

/// Borderless, non-activating panel: it takes keyboard focus without activating the app,
/// so the previously frontmost app stays the target for paste and window actions.
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: PalettePanel
    let model: PaletteModel
    private weak var field: NSTextField?
    private var monitor: Any?
    private var contentHeight: CGFloat = 120

    init(model: PaletteModel) {
        self.model = model
        panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: Theme.width, height: 120),
                             styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                             backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self

        let root = PaletteView(model: model,
                               onCreateField: { [weak self] in self?.field = $0 },
                               onHeight: { [weak self] in self?.setHeight($0) })
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.type == .flagsChanged {
                self.model.handleFlagsChanged(event)
                return event
            }
            return self.model.handleKey(event) ? nil : event
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let top = frame.maxY - frame.height * 0.18
            panel.setFrame(NSRect(x: frame.midX - Theme.width / 2, y: top - contentHeight,
                                  width: Theme.width, height: contentHeight), display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        if let field { panel.makeFirstResponder(field) }
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func setHeight(_ h: CGFloat) {
        guard h > 0, abs(h - contentHeight) > 0.5 else { return }
        contentHeight = h
        var f = panel.frame
        let top = f.maxY
        f.size.height = h
        f.origin.y = top - h
        panel.setFrame(f, display: true)
        panel.invalidateShadow()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere closes the panel, like Spotlight. Menus (extension dropdown) keep it open.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow, NSApp.keyWindow == nil || NSApp.keyWindow !== self.panel else { return }
            if NSApp.windows.contains(where: { $0.isVisible && $0.className.contains("Menu") }) { return }
            self.model.host.hide()
        }
    }
}

/// Small toast near the bottom of the screen.
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ message: String) {
        let view = NSHostingView(rootView:
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.panel, in: Capsule())
                .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
                .fixedSize()
        )
        let size = view.fittingSize
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            return p
        }()
        panel = p
        p.contentView = view
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + f.height * 0.12, width: size.width, height: size.height), display: true)
        }
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak p] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p?.animator().alphaValue = 0 }) { p?.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}
